import Foundation

/// 容器的实际规整动作：ffprobe 探测编码 → 决定目标容器 → ffmpeg remux → 删源。
/// 纯决策在 `ContainerPolicy`，这里只做 IO。
public enum ContainerFinalizer {
    /// - Returns: 规整后的路径；不需要或失败时返回原路径。
    public static func finalize(
        path: String,
        policy: [String: String],
        ffprobePath: String?,
        ffmpegPath: String?
    ) async -> String {
        guard !policy.isEmpty else { return path }
        guard let ffprobePath else {
            Log.warning("找不到 ffprobe，跳过容器规整：\(path)")
            return path
        }
        let vcodec = await probe(path: path, stream: "v:0", tool: ffprobePath)
        guard !vcodec.isEmpty else { return path }
        let acodec = await probe(path: path, stream: "a:0", tool: ffprobePath)
        let ext = (path as NSString).pathExtension

        guard let target = ContainerPolicy.targetContainer(
            vcodec: vcodec, acodec: acodec, policy: policy, currentExtension: ext
        ) else {
            return path
        }

        guard let ffmpegPath else {
            Log.warning("找不到 ffmpeg，跳过容器规整：\(path)")
            return path
        }

        let base = (path as NSString).deletingPathExtension
        let destination = base + "." + target
        let arguments = ContainerPolicy.remuxArguments(
            source: path,
            destination: destination,
            videoCodec: vcodec,
            audioCodec: acodec,
            targetExtension: target
        )

        let result = await Subprocess.run(
            executable: ffmpegPath,
            arguments: arguments,
            environment: Subprocess.environment(),
            timeout: 900
        )
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: destination) else {
            Log.warning("ffmpeg 规整失败（.\(ext) → .\(target)）：\(result.stderr.suffix(400))")
            return path
        }

        try? FileManager.default.removeItem(atPath: path)
        Log.info("容器规整：.\(ext) → .\(target)  \(vcodec)/\(acodec.isEmpty ? "无音轨" : acodec)")
        return destination
    }

    /// ffprobe 取某条流的 codec_name（小写）。失败返回空串。
    static func probe(path: String, stream: String, tool: String) async -> String {
        let result = await Subprocess.run(
            executable: tool,
            arguments: [
                "-v", "error",
                "-select_streams", stream,
                "-show_entries", "stream=codec_name",
                "-of", "default=noprint_wrappers=1:nokey=1",
                path,
            ],
            environment: Subprocess.environment(),
            timeout: 60
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}