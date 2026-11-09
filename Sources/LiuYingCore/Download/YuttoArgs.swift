import Foundation

/// 构造 yutto 的 argv。顺序严格对齐旧版 Python 的 build_args（456–494 行），
/// 因为 yutto 对同名参数后者覆盖前者，顺序会影响最终取值。
///
/// 纯函数：auth 文件是否存在由调用方注入，测试不需要碰文件系统。
public enum YuttoArgs {
    public static func build(
        config: YuttoConfig,
        url: String,
        downloadDir: String,
        workDir: String? = nil,
        authFileExists: Bool = false,
        binaryPath: String
    ) -> [String] {
        var args: [String] = [binaryPath]

        // 投稿视频默认只下 P1，需要 --batch 才会展开该视频的全部分 P。
        if config.downloadAllPages {
            args.append("--batch")
        }

        args += [url, "-d", downloadDir, "--no-progress", "--no-color"]

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