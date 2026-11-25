import Foundation

/// 构造 bili-dl 的 argv。bili-dl 被改造成接受 yutto 的整套参数（未知参数静默忽略），
/// 因此这里的顺序与旧版 yutto 的 build_args 保持一致，配置也复用同一语义。
///
/// 纯函数：auth 文件是否存在由调用方注入，测试不需要碰文件系统。
public enum BiliDlArgs {
    public static func build(
        config: BiliDlConfig,
        url: String,
        downloadDir: String,
        workDir: String? = nil,
        authFileExists: Bool = false,
        binaryPath: String,
        resultPath: String? = nil,
        emitProgressJSON: Bool = false
    ) -> [String] {
        var args: [String] = [binaryPath]

        // 投稿视频默认只下 P1，需要 --batch 才会展开该视频的全部分 P。
        if config.downloadAllPages {
            args.append("--batch")
        }

        args += [url, "-d", downloadDir, "--no-progress", "--no-color"]

        // NDJSON 进度：stdout 每行一个事件，由 DownloadBackend 解析成 DownloadProgress。
        // 与 --no-progress 不冲突：前者关掉人读的进度条，后者开启机器读的事件流。
        if emitProgressJSON {
            args.append("--progress-json")
        }

        // 结构化结果。刻意用等号形式（--result-json=<path>）：单个 token，
        // 老版本 bili-dl 不认识该 flag 时会整条忽略，不会把路径当成位置参数
        // 当成第二个待下载 URL —— 这正是「旧内嵌二进制也能跑」的前提。
        if let resultPath, !resultPath.isEmpty {
            args.append("--result-json=\(resultPath)")
        }

        // --tmp-dir 是 yutto 兼容参数；bili-dl 的宽松解析器接受但不改动产物落点。
        // 保留以对齐 yutto argv 契约（产物位置以 --result-json 为准，不再靠目录差集）。
        if let workDir {
            args += ["--tmp-dir", workDir]
        }
        if config.videoQuality != 0 {
            args += ["-q", String(config.videoQuality)]
        }
        if config.audioQuality != 0 {
            args += ["-aq", String(config.audioQuality)]
        }
        if !config.vcodec.isEmpty {
            args += ["--vcodec", config.vcodec]
        }
        if !config.vcodecPriority.isEmpty {
            args += ["--download-vcodec-priority", config.vcodecPriority.joined(separator: ",")]
        }
        if !config.outputFormat.isEmpty {
            args += ["--output-format", config.outputFormat]
        }
        if !config.subpathTemplate.isEmpty {
            args += ["-tp", config.subpathTemplate]
        }

        if !config.downloadDanmaku { args.append("--no-danmaku") }
        if !config.downloadSubtitle { args.append("--no-subtitle") }
        args.append(config.saveCover ? "--save-cover" : "--no-cover")

        // auth.toml 不存在时退化到未登录（最高 1080P），不能传一个不存在的路径。
        if authFileExists {
            args += ["--auth-file", AppIdentity.expand(config.authFile)]
            if !config.authProfile.isEmpty {
                args += ["--auth-profile", config.authProfile]
            }
        }

        args += config.extraArgs
        return args
    }
}
