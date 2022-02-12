//
//  ShareViewController.swift
//  iMastShare
//
//  Created by rinsuki on 2017/06/07.
//  
//  ------------------------------------------------------------------------
//
//  Copyright 2017-2019 rinsuki and other contributors.
// 
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
// 
//      http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import UIKit
import Social
import Hydra
import SwiftyJSON
import Alamofire
import Fuzi
import MobileCoreServices
import iMastiOSCore

class ShareViewController: SLComposeServiceViewController {
    
    var isMastodonLogged = false
    var userToken = MastodonUserToken.getLatestUsed() {
        didSet {
            accountConfig.value = self.userToken!.acct
        }
    }
    var accountConfig = SLComposeSheetConfigurationItem()!
    var visibilityConfig = SLComposeSheetConfigurationItem()!
    var visibility: MastodonPostVisibility = .public {
        didSet {
            visibilityConfig.value = visibility.localizedName
        }
    }
    var postMedia: [UploadableMedia] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Mastodonで共有"
        self.isMastodonLogged = self.userToken != nil
        if !self.isMastodonLogged {
            alert(
                title: "エラー",
                message: "iMastにMastodonのアカウントが設定されていません。\niMastを起動してアカウントを登録してください。"
            ) {
                self.cancel()
            }
            return
        }
        accountConfig.title = "アカウント"
        accountConfig.value = self.userToken!.acct
        accountConfig.tapHandler = {
            let VC = ShareAccountSelectorTableViewController()
            VC.nowUserTokenId = self.userToken!.id!
            VC.parentVC = self
            self.pushConfigurationViewController(VC)
        }
        visibilityConfig.title = "公開範囲"
        visibilityConfig.value = "公開"
        visibilityConfig.tapHandler = {
            let VC = ShareVisibilityTableViewController()
            VC.parentVC = self
            self.pushConfigurationViewController(VC)
        }

        let itemHandlers: [CFString: NSItemProvider.CompletionHandler] = [
            kUTTypeURL: self.processUrl,
            kUTTypeImage: self.processImage,
        ]

        for inputItem in self.extensionContext!.inputItems as! [NSExtensionItem] {
            for itemProvider in inputItem.attachments ?? [] {
                print(itemProvider)
                for (uti, handler) in itemHandlers {
                    if itemProvider.hasItemConformingToTypeIdentifier(uti as String) {
                        itemProvider.loadItem(forTypeIdentifier: uti as String, options: nil, completionHandler: handler)
                    }
                }
            }
        }
        self.validateContent()
    }
    
    override func isContentValid() -> Bool {
        // Do validation of contentText and/or NSExtensionContext attachments here
        let textLength = self.contentText.count
        self.charactersRemaining = 500 - textLength as NSNumber
        return self.isMastodonLogged && (textLength > 0 || postMedia.count > 0)
    }
    
    func processUrl(item: NSSecureCoding?, error: Error?) {
        if let error = error {
            self.extensionContext!.cancelRequest(withError: error)
            return
        }
        guard var url = item as? NSURL else {
            return
        }
        if url.scheme == "file" {
            return
        }
        let query = urlComponentsToDict(url: url as URL)
        
        // Twitterトラッキングを蹴る
        if Defaults.shareNoTwitterTracking, url.host?.hasSuffix("twitter.com") ?? false {
            var urlComponents = URLComponents(string: url.absoluteString!)!
            urlComponents.queryItems = (urlComponents.queryItems ?? []).filter({$0.name != "ref_src" && $0.name != "s"})
            if (urlComponents.queryItems ?? []).count == 0 {
                urlComponents.query = nil
            }
            let urlString = (urlComponents.url?.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))!
            url = NSURL(string: urlString)!
        }
        if Defaults.shareNoSpotifySIParameter, url.host == "open.spotify.com" {
            var urlComponents = URLComponents(string: url.absoluteString!)!
            urlComponents.queryItems = (urlComponents.queryItems ?? []).filter({$0.name != "si"})
            if (urlComponents.queryItems ?? []).count == 0 {
                urlComponents.query = nil
            }
            let urlString = (urlComponents.url?.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))!
            url = NSURL(string: urlString)!
        }
        var postUrl = url.absoluteString
        
        // Twitter共有の引き継ぎ
        if url.host == "twitter.com" && url.path == "/intent/tweet" {
            var twitterPostText: String = ""
            if let text = query["text"] {
                twitterPostText += text
            }
            if let url = query["url"] {
                twitterPostText += " " + url
            }
            if let hashtags = query["hashtags"] {
                hashtags.components(separatedBy: ",").forEach { hashtag in
                    twitterPostText += " #" + hashtag
                }
            }
            if let via = query["via"] {
                twitterPostText += " https://twitter.com/\(via)さんから"
            }
            postUrl = nil
            DispatchQueue.main.sync {
                self.textView.text = twitterPostText
            }
        }
        
        // なうぷれ対応
        processSpotifyURL(url: url)
        
        if let postUrl = postUrl {
            DispatchQueue.main.sync {
                self.textView.text += "\n" + postUrl
            }
        }
        
        DispatchQueue.main.sync {
            self.validateContent()
        }
    }

    func processSpotifyURL(url: NSURL) {
        if Defaults.usingNowplayingFormatInShareSpotifyUrl,
            url.scheme == "https", url.host == "open.spotify.com",
            let path = url.path, path.starts(with: "/track/"),
            let objectId = path.pregMatch(pattern: "^/track/(.+)$").safe(1) {
            let previewUrl = "https://open.spotify.com/embed/track/\(objectId)"
            Alamofire.request(previewUrl).responseData { res in
                switch res.result {
                case .success(let data):
                    guard let doc = try? Fuzi.HTMLDocument(data: data) else {
                        print("SpotifyNowPlayingError: Fuzi.HTMLDocumentでパースに失敗")
                        return
                    }
                    guard let trackElement = doc.xpath("//*[@id='resource']").first else {
                        print("SpotifyNowPlayingError: script#resourceがなかった")
                        return
                    }
                    
                    struct SpotifyArtist: Codable {
                        var name: String
                    }
                    
                    struct SpotifyAlbum: Codable {
                        var name: String
                        var artists: [SpotifyArtist]
                    }
                    
                    struct SpotifyTrack: Codable {
                        var name: String
                        var album: SpotifyAlbum
                        var artists: [SpotifyArtist]
                    }
                    
                    let decoder = JSONDecoder()
                    let result = Result { try decoder.decode(SpotifyTrack.self, from: trackElement.stringValue.data(using: .utf8)!) }
                    guard case .success(let track) = result else {
                        print("SpotifyNowPlayingError: Failed to decode script#resource", result)
                        return
                    }
                    
                    let nowPlayingText = Defaults.nowplayingFormat
                        .replacingOccurrences(of: "{title}", with: track.name)
                        .replacingOccurrences(of: "{artist}", with: track.artists.map { $0.name }.joined(separator: ", "))
                        .replacingOccurrences(of: "{albumTitle}", with: track.album.name)
                        .replacingOccurrences(of: "{albumArtist}", with: track.album.artists.map { $0.name }.joined(separator: ", "))
                    print(Thread.isMainThread)
                    DispatchQueue.mainSafeSync {
                        self.textView.text = nowPlayingText
                    }
                case .failure(let error):
                    print("GPMNowPlayingError: Failed fetch Information", error)
                }
            }
        }
    }
    
    func processImage(item: NSSecureCoding?, error: Error?) {
        if let error = error {
            self.extensionContext!.cancelRequest(withError: error)
            return
        }
        if let imageData = item as? Data {
            self.postMedia.append(UploadableMedia(format: .png, data: imageData, url: nil, thumbnailImage: UIImage(data: imageData)!))
        } else if let imageUrl = item as? NSURL {
            print(imageUrl)
            if imageUrl.isFileURL, let data = try? Data(contentsOf: imageUrl as URL) {
                self.postMedia.append(UploadableMedia(format: (imageUrl.pathExtension ?? "").lowercased() == "png" ? .png : .jpeg, data: data, url: nil, thumbnailImage: UIImage(data: data)!))
            }
        } else if let image = item as? UIImage {
            self.postMedia.append(UploadableMedia(format: .png, data: image.pngData()!, url: nil, thumbnailImage: image))
        }
    }
    
    override func didSelectPost() {
        // This is called after the user selects Post. Do the upload of contentText and/or NSExtensionContext attachments.
    
        // Inform the host that we're done, so it un-blocks its UI. Note: Alternatively you could call super's -didSelectPost, which will similarly complete the extension context.
        let alert = UIAlertController(title: "投稿中", message: "しばらくお待ちください", preferredStyle: UIAlertController.Style.alert)
        present(alert, animated: true, completion: nil)
        Task {
            do {
                var images: [JSON] = []
                for medium in self.postMedia {
                    let result = try await self.userToken!.upload(file: medium.toUploadableData(), mimetype: medium.getMimeType()).wait()
                    if result["_response_code"].intValue >= 400 {
                        throw APIError.errorReturned(errorMessage: result["error"].stringValue, errorHttpCode: result["_response_code"].intValue)
                    }
                    if result["id"].exists() {
                        images.append(result)
                    } else {
                        print(result)
                    }
                }
                let res = try await MastodonEndpoint.CreatePost(
                    status: self.contentText,
                    visibility: self.visibility,
                    // TODO: ちゃんと upload で MastodonMedia を返すようにしてそのidを使う
                    mediaIds: images.map { .init(string: $0["id"].stringValue) }
                ).request(with: self.userToken!)
                alert.dismiss(animated: true)
                self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                await MainActor.run { alert.dismiss(animated: false) }
                switch error {
                case APIError.errorReturned(errorMessage: let msg, errorHttpCode: let httpCode):
                    await apiError(msg, httpCode)
                default:
                    await apiError("未知のエラーが発生しました。\n\(error.localizedDescription)", -1001)
                }
                await MainActor.run { self.extensionContext!.cancelRequest(withError: error) }
            }
        }
    }

    override func configurationItems() -> [Any]! {
        // To add configuration options via table cells at the bottom of the sheet, return an array of SLComposeSheetConfigurationItem here.
        return [
            accountConfig,
            visibilityConfig,
        ]
    }
    
    override func loadPreviewView() -> UIView! {
        if Defaults.useCustomizedSharePreview {
            return nil
        } else {
            return super.loadPreviewView()
        }
    }
}
