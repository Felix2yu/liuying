import Foundation

/// 按视频编码把成品规整到目标容器。
///
/// yutto 用 `--output-format mp4` 时，av1 会被装进 mp4；但本机播放体验与编码优先级都更偏向
/// 「av1 → mkv、hevc → mov、avc → mp4」。另外 mp4/mov 装不下 FLAC/ALAC 等无损音轨，
/// 这时必须退回 mkv 才能保留无损。
public enum ContainerPolicy {
    public static let losslessAudioCodecs: Set<String> = ["flac", "alac", "truehd", "dts", "eac3", "opus"]

    /// ffprobe 报的编码名归一化。`avc1` / `h264` 都是 H.264。
    public static func normalizeVideoCodec(_ raw: String) -> String {
        switch raw.lowercased() {
        case "avc1", "h264": "avc"
        case let other: other
        }
    }

    /// 返回目标扩展名（不含点）。nil 表示**不需要改动**。
    /// - Parameters:
    ///   - vcodec: ffprobe `v:0` 的 codec_name；空串表示探测失败。
    ///   - acodec: ffprobe `a:0` 的 codec_name；无音轨时为空。
    public static func targetContainer(
        vcodec: String,
        acodec: String,
        policy: [String: String],
        currentExtension: String
    ) -> String? {
        guard !policy.isEmpty, !vcodec.isEmpty else { return nil }
        let normalized = normalizeVideoCodec(vcodec)
        guard var target = policy[normalized] else { return nil }

        if (target == "mp4" || target == "mov"), losslessAudioCodecs.contains(acodec.lowercased()) {
            target = "mkv"
        }
        if currentExtension.lowercased() == target.lowercased() { return nil }
        return target
    }

    /// ffmpeg remux 的参数（不含可执行文件路径）。
    public static func remuxArguments(
        source: String,
        destination: String,
        videoCodec: String,
        audioCodec: String,
        targetExtension: String
    ) -> [String] {
        var args = ["-y", "-i", source, "-c:v", "copy"]
        let isMp4Family = targetExtension == "mp4" || targetExtension == "mov"
        // mkv 可保留任意音轨；mp4/mov 遇到无损音轨则转 AAC（兜底，正常走不到，因为上面已改判 mkv）。
        if isMp4Family, losslessAudioCodecs.contains(audioCodec.lowercased()) {
            args += ["-c:a", "aac", "-b:a", "320k"]
        } else {
            args += ["-c:a", "copy"]
        }
        if normalizedIsHEVC(videoCodec), isMp4Family {
            args += ["-tag:v", "hvc1"]
        }
        if targetExtension == "mp4" {
            args += ["-movflags", "+faststart"]
        }
        args.append(destination)
        return args
    }

    static func normalizedIsHEVC(_ raw: String) -> Bool {
        raw.lowercased() == "hevc" || raw.lowercased() == "h265"
    }
}