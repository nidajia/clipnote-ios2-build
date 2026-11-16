import SwiftUI

/// 「一图胜千言」：把一条内容画成一张竖版卡片图。
///
/// 两个决定值得写下来：
/// 1. **真的调图像模型**，不是本地排版冒充（路线表里明确区分过这两件事）。
/// 2. 但**文字不交给模型画**。图像模型写中文十次有八次是错字，
///    所以模型只负责背景插画，标题和要点由 App 用系统字体叠上去——
///    这样「出自模型」和「看得清字」两件事都不牺牲。
enum ImageGen {
    enum Failure: LocalizedError {
        case notConfigured
        case transport(String)
        case http(Int, String)
        case unparsable(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "还没配图像模型。到「我 → AI 设置」里填一个（硅基流动可用 Kwai-Kolors/Kolors）。"
            case .transport(let message):
                return "连不上图像服务：\(message)"
            case .http(let code, let body):
                return "图像服务返回 \(code)：\(body)"
            case .unparsable(let body):
                return "看不懂图像服务的返回：\(body)"
            }
        }
    }

    /// 背景插画的提示词。**不要求出现任何文字**——见文件头说明。
    static func backgroundPrompt(title: String, summary: String, points: [String]) -> String {
        let topic = [title, summary].filter { !$0.isEmpty }.joined(separator: "。")
        let hints = points.prefix(3).joined(separator: "；")
        return """
        竖版海报背景插画，主题：\(topic.prefix(160))。
        要点氛围：\(hints.prefix(120))。
        风格：极简、深色背景、柔和渐变光、留白充足、几何色块，
        不要任何文字、字母、数字、水印；主体居中偏上，下半部留出大片空白。
        """
    }

    static func generate(prompt: String, config: AIConfig,
                         session: URLSession = .shared) async throws -> UIImage {
        guard config.imageConfigured, let url = config.imageEndpoint else {
            throw Failure.notConfigured
        }

        // 先按硅基流动（Kolors）的参数发一次；400 时再按 OpenAI 的字段名重试一次。
        // 两家的字段名确实不同（image_size/batch_size vs size/n），
        // 与其让用户选「你用的是哪家」，不如自己试一次。
        let bodies: [[String: Any]] = [
            ["model": config.imageModel, "prompt": prompt,
             "image_size": "1024x1024", "batch_size": 1,
             "num_inference_steps": 20, "guidance_scale": 7.5],
            ["model": config.imageModel, "prompt": prompt,
             "size": "1024x1024", "n": 1],
        ]

        var lastError: Failure = .transport("没有发出请求")
        for body in bodies {
            do {
                return try await once(url: url, body: body, key: config.key, session: session)
            } catch let failure as Failure {
                lastError = failure
                // 只有 400 值得换一套字段再试；401/429 换字段也没用
                if case .http(let code, _) = failure, code == 400 { continue }
                throw failure
            }
        }
        throw lastError
    }

    private static func once(url: URL, body: [String: Any], key: String,
                             session: URLSession) async throws -> UIImage {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 生图比聊天慢，20 秒不够
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unparsable(String(data: data.prefix(80), encoding: .utf8) ?? "")
        }

        // 三种常见返回：images[].url（硅基流动）、data[].url（OpenAI 新版）、
        // data[].b64_json（OpenAI 老版）。都认。
        if let list = root["images"] as? [[String: Any]],
           let first = list.first, let link = first["url"] as? String,
           let remote = URL(string: link) {
            return try await download(remote, session: session)
        }
        if let list = root["data"] as? [[String: Any]], let first = list.first {
            if let link = first["url"] as? String, let remote = URL(string: link) {
                return try await download(remote, session: session)
            }
            if let b64 = first["b64_json"] as? String,
               let raw = Data(base64Encoded: b64), let image = UIImage(data: raw) {
                return image
            }
        }
        throw Failure.unparsable(String(data: data.prefix(120), encoding: .utf8) ?? "")
    }

    private static func download(_ url: URL, session: URLSession) async throws -> UIImage {
        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let image = UIImage(data: data) else {
            throw Failure.unparsable("下载到的不是图片")
        }
        return image
    }
}
