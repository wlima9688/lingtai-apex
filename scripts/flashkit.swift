// ============================================================
// FlashKit — 确认闸的可视化闭环
//
// 为什么单独一个文件：
//   v1.3 最大的失败不是「不会执行」，而是**确认提示打在了终端 stdout**，
//   而用户人在 flash 面板前 —— 一个需要确认的流程，如果确认入口不在
//   用户眼前，它就等于死锁（用户原话：「他让我确认，可我根本不知道
//   该在界面哪里去确认」）。
//
// 机制：文件队列 + 轮询。
//   1. 任何脚本遇到需确认的动作 → 往 queue/pending/ 写一个 JSON 文件
//   2. flash 每 400ms 扫一遍目录，发现新文件就在面板上渲染成按钮
//   3. 用户点「确认」→ flash 写queue/answered/<id>.json
//   4. 原脚本下次轮询时读到 answered，就继续执行
//
// 为什么用文件而不是 socket/DB：
//   · 零依赖（bash 脚本和 Swift 都能读写）
//   · 可观测（出问题时用户能直接 cat 文件看到卡在哪）
//   · 崩溃安全（文件天然持久，进程重启不丢待确认项）
// ============================================================

import Foundation

/// 待确认项的存放目录（由 common.sh 的 QUEUE_DIR 保持一致）
func queueDir() -> String {
    // 2026-10-25：自检必须能把队列指到临时目录，否则它造的假待确认项
    // 会亮起菜单栏 ⚠️N，用户以为程序坏了（真实发生过）。
    if let override = ProcessInfo.processInfo.environment["LINGTAI_QUEUE_DIR"], !override.isEmpty {
        return override
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.workbuddy/skills/mac-control/queue"
}

struct Pending: Codable, Equatable {
    var id: String
    var title: String        // 「给张三发微信」
    var detail: String      // 消息正文 / 具体做什么
    var script: String// 确认后该跑什么（脚本绝对路径）
    var args: [String]// 参数
    var created: Double      // 创建时间戳
    var risk: String         // "对外发送" / "删除" / "不可逆"
}

/// 扫描待确认队列。
/// ⚠ 排序很重要：多个待确认项时必须按创建时间**从旧到新**返回，
///   否则用户点了「确认」可能确认的是另一条 —— 这种错配的代价是发错消息。
func loadPending() -> [Pending] {
    let dir = queueDir() + "/pending"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var items: [Pending] = []
    for f in files where f.hasSuffix(".json") {
        let path = dir + "/" + f
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        if let p = try? JSONDecoder().decode(Pending.self, from: data) {
            items.append(p)
        }
    }
    // 从旧到新：先来的先确认，符合直觉
    return items.sorted { $0.created < $1.created }
}

/// 回答一个待确认项。
/// - Parameter approve: true=确认执行，false=放弃
/// - Returns: 是否成功回答
func answer(_ id: String, approve: Bool) -> Bool {
    let dir = queueDir() + "/answered"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let payload: [String: Any] = ["id": id, "approved": approve, "at": Date().timeIntervalSince1970]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
    let ok = FileManager.default.createFile(atPath: "\(dir)/\(id).json", contents: data)
    // 无论成败都清掉 pending —— 否则会永远重复询问
    try? FileManager.default.removeItem(atPath: "\(queueDir())/pending/\(id).json")
    return ok
}

/// 检查某项是否已被回答。给 bash 脚本用（它们直接读文件）。
func isAnswered(_ id: String) -> Bool {
    FileManager.default.fileExists(atPath: "\(queueDir())/answered/\(id).json")
}

// MARK: - shell 侧的反向接口
//
// flash 提供这两个命令给 shell 调用，避免两边各写一套队列逻辑：
//   flash queue add    --id X --title Y --detail Z --script S --args A --risk R
//   flash queue check  --id X     → 输出 approved:true / approved:false / pending
//   flash queue list                → 列出全部待确认（JSON）
//   flash queue consume --id X      → 回答后清理（脚本执行完调用）

func queueAdd(_ a: Args) {
    let id = a.str("id", UUID().uuidString)
    let p = Pending(
        id: id,
        title: a.str("title", "待确认操作"),
        detail: a.str("detail"),
        script: a.str("script"),
        args: a.list("args"),
        created: Date().timeIntervalSince1970,
        risk: a.str("risk", "不可逆")
    )
    let dir = queueDir() + "/pending"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // ⚠ createFile 返回 Bool 不是 Optional，不能 `let _ =` 绑定（编译器会报
    //   "initializer for conditional binding must have Optional type"）
    guard let data = try? JSONEncoder().encode(p),
          FileManager.default.createFile(atPath: "\(dir)/\(id).json", contents: data) else {
        FileHandle.standardOutput.write(Data("{\"ok\":false,\"error\":\"QUEUE_WRITE_FAILED\"}\n".utf8))
        exit(1)
    }
    FileHandle.standardOutput.write(Data("{\"ok\":true,\"id\":\"\(id)\"}\n".utf8))
}

func queueCheck(_ a: Args) {
    let id = a.str("id")
    let apath = "\(queueDir())/answered/\(id).json"
    guard let data = FileManager.default.contents(atPath: apath),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let approved = obj["approved"] as? Bool else {
        FileHandle.standardOutput.write(Data("{\"state\":\"pending\"}\n".utf8))
        exit(0)
    }
    FileHandle.standardOutput.write(Data("{\"state\":\"answered\",\"approved\":\(approved)}\n".utf8))
}

func queueList(_ a: Args) {
    let items = loadPending()
    let enc = JSONEncoder()
    enc.outputFormatting = .prettyPrinted
    if let data = try? enc.encode(items) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        FileHandle.standardOutput.write(Data("[]\n".utf8))
    }
}

/// 脚本执行完毕（成功或失败）后清理 answered 记录，避免队列无限增长。
func queueConsume(_ a: Args) {
    let id = a.str("id")
    try? FileManager.default.removeItem(atPath: "\(queueDir())/answered/\(id).json")
    FileHandle.standardOutput.write(Data("{\"ok\":true}\n".utf8))
}

/// 列出队列统计（诊断用）。
func queueStat() {
    let p = loadPending()
    let f = (try? FileManager.default.contentsOfDirectory(atPath: queueDir() + "/answered")) ?? []
    print("=== 闪控确认队列 ===")
    print("  待确认: \(p.count) 项")
    print("  已回答待清理: \(f.count) 项")
    print("  目录: \(queueDir())")
    if p.isEmpty {
        print("  （没有卡住的确认）")
    } else {
        for i in p {
            print("  · \(i.title) — \(i.detail)")
        }
    }
}
