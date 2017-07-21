//
//  TealiumTagManagement.swift
//
//  Created by Jason Koo on 12/14/16.
//  Copyright © 2016 Apple, Inc. All rights reserved.
//

import Foundation

// MARK:
// MARK: CONSTANTS

enum TealiumTagManagementKey {
    static let dispatchService = "dispatch_service"
    static let jsCommand = "js_command"
    static let jsResult = "js_result"
    static let moduleName = "tagmanagement"
    static let responseHeader = "response_headers"
    static let payload = "payload"
    static let wasQueud = "was_queued"
}

enum TealiumTagManagementConfigKey {
    static let disable = "disable_tag_management"
    static let maxQueueSize = "tagmanagement_queue_size"
    static let overrideURL = "tagmanagement_override_url"
}

enum TealiumTagManagementValue {
    static let defaultQueueSize = 100
}

enum TealiumTagManagementError : Error {
    case couldNotCreateURL
    case couldNotLoadURL
    case couldNotJSONEncodeData
    case noDataToTrack
    case webViewNotYetReady
    case unknownDispatchError
}

// MARK:
// MARK: EXTENSIONS

extension TealiumConfig {
    
    func disableTagManagement() {
        
        optionalData[TealiumTagManagementConfigKey.disable] = true
        
    }
  
    func setTagManagementQueueSize(to: Int) {

        optionalData[TealiumTagManagementConfigKey.maxQueueSize] = to
        
    }
    
    func setTagManagementOverrideURL(string: String) {
        
        optionalData[TealiumTagManagementConfigKey.overrideURL] = string
    }
    
}

// NOTE: UIWebview, the primary element of TealiumTagManagement can not run in XCTests.

#if TEST
#else
extension Tealium {
    
    public func tagManagement() -> TealiumTagManagement? {
        
        guard let module = modulesManager.getModule(forName: TealiumTagManagementKey.moduleName) as? TealiumTagManagementModule else {
            return nil
        }
        
        return module.tagManagement
        
    }
}
#endif

// MARK:
// MARK: MODULE SUBCLASS

class TealiumTagManagementModule : TealiumModule {
    
    // Queue for staging calls to this dispatch service, as initial calls
    // likely to incoming before webView is ready.
    
    /// Overridable completion handler for module send command.
    var sendCompletion : (TealiumTagManagementModule, TealiumTrackRequest) -> Void = { (_ module:TealiumTagManagementModule, _ track:TealiumTrackRequest) in
    
        #if TEST
        #else
            // Default behavior
            module.tagManagement.track(track.data,
                       completion:{(success, info, error) in
                        
                let newTrack = TealiumTrackRequest(data: track.data,
                                                   info: info,
                                                   completion: track.completion)
                if error != nil {
                    module.didFailToFinish(newTrack,
                                           error:error!)
                    return
                }
                module.didFinish(newTrack)
                        
            })
        #endif
        
    }

    override class func moduleConfig() -> TealiumModuleConfig {
        return TealiumModuleConfig(name: TealiumTagManagementKey.moduleName,
                                   priority: 1100,
                                   build: 2,
                                   enabled: true)
    }
    
    #if TEST
    #else
    var tagManagement = TealiumTagManagement()
    
    override func enable(_ request: TealiumEnableRequest) {
    
        let config = request.config
        if config.optionalData[TealiumTagManagementConfigKey.disable] as? Bool == true {
            DispatchQueue.main.async {
                self.tagManagement.disable()
            }
            self.didFinish(request)
            return
        }
    
        let account = config.account
        let profile = config.profile
        let environment = config.environment
        let overrideUrl = config.optionalData[TealiumTagManagementConfigKey.overrideURL] as? String
        
        DispatchQueue.main.async {

            self.tagManagement.enable(forAccount: account,
                                 profile: profile,
                                 environment: environment,
                                 overrideUrl: overrideUrl,
                                 completion: {(success, error) in
            
                if let e = error {
                    self.didFailToFinish(request,
                                         error: e)
                    return
                }
                self.isEnabled = true
                self.didFinish(request)
                                    
            })
        }
        
    }

    override func disable(_ request: TealiumDisableRequest) {

        isEnabled = false
        DispatchQueue.main.async {

            self.tagManagement.disable()

        }
        didFinish(request)
    }

    override func track(_ track: TealiumTrackRequest) {
        
        if isEnabled == false {
            // Ignore while disabled
            didFinishWithNoResponse(track)
            return
        }
        
        if track.wasSent == true {
            didFinishWithNoResponse(track)
            return
        }
        
        var newTrack = TealiumTrackRequest(data: track.data,
                                           info: nil,
                                           completion: track.completion)
        newTrack.wasSent = true
        
        // Dispatch to main thread since webview requires main thread.
        DispatchQueue.main.async {
            
            // Webview has failed for some reason
            if self.tagManagement.isWebViewReady() == false {
                self.didFailToFinish(newTrack,
                                     error: TealiumTagManagementError.webViewNotYetReady)
                return
            }

            self.sendCompletion(self, newTrack)

        }
        
        didFinishWithNoResponse(track)

    }
    #endif

}

// MARK:
// MARK: TAG MANAGEMENT

#if TEST
#else
import UIKit

enum TealiumTagManagementNotificationKey {
    static let urlRequestMade = "com.tealium.tagmanagement.urlrequest"
    static let jsCommandRequested = "com.tealium.tagmanagement.jscommand"
    static let jsCommand = "js"
    
}

/// TIQ Supported dispatch service Module. Utlizies older but simpler UIWebView vs. newer WKWebView.
public class TealiumTagManagement : NSObject {
    
    static let defaultUrlStringPrefix = "https://tags.tiqcdn.com/utag"
    
    var delegates = TealiumMulticastDelegate<UIWebViewDelegate>()
    var didWebViewFinishLoading = false
    var account : String = ""
    var profile : String = ""
    var environment : String = ""
    var urlString : String?
    var webView : UIWebView?
    var completion : ((Bool, Error?)->Void)?
    lazy var defaultUrlString : String = {
        let urlString = "\(defaultUrlStringPrefix)/\(self.account)/\(self.profile)/\(self.environment)/mobile.html?"
        return urlString
    }()
    lazy var urlRequest : URLRequest? = {
        guard let url = URL(string: self.urlString ?? self.defaultUrlString) else {
            return nil
        }
        let request = URLRequest(url: url)
        return request
    }()    
    
    // MARK: PUBLIC
    
    // TODO: Add overrideURL optional arg
    
    /// Enable webview system.
    ///
    /// - Parameters:
    ///   - forAccount: Tealium account.
    ///   - profile: Tealium profile.
    ///   - environment: Tealium environment.
    ///   - overridUrl : Optional alternate url to load utag/tealium from.
    /// - Returns: Boolean if a webview is ready to start.
    func enable(forAccount: String,
                profile: String,
                environment: String,
                overrideUrl : String?,
                completion: ((_ success:Bool, _ error: Error?)-> Void)?) {
        
        
        if self.webView != nil {
            // WebView already enabled.
            return
        }
        
        self.account = forAccount
        self.profile = profile
        self.environment = environment
        if let overrideUrl = overrideUrl {
            self.urlString = overrideUrl
        } else {
            self.urlString = defaultUrlString
        }
        
        guard let request = self.urlRequest else {
            completion?(false, TealiumTagManagementError.couldNotCreateURL)
            return
        }
        self.webView = UIWebView()
        self.webView?.delegate = self
        self.webView?.loadRequest(request)
        
        self.enableNotifications()
        
        self.completion = completion
        
    }
    
    
    func enableNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(processRequest),
                                               name: Notification.Name.init(TealiumTagManagementNotificationKey.jsCommandRequested),
                                               object: nil)
    }
    
    func processRequest(sender: Notification){
        
        guard let jsCommandString = sender.userInfo?[TealiumTagManagementNotificationKey.jsCommand] as? String else {
            return
        }
        // Error reporting?
        DispatchQueue.main.async {
            
            let _ = self.webView?.stringByEvaluatingJavaScript(from: jsCommandString)
        }
        
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Disable the webview system.
    func disable() {
        
        self.webView?.stopLoading()
        self.webView = nil
        
    }
    
    func isTagManagementEnabled() -> Bool {
        
        return webView != nil
        
    }
    
    /// Internal webview status check.
    ///
    /// - Returns: Bool indicating whether or not the internal webview is ready for dispatching.
    func isWebViewReady() -> Bool {
        
        if self.webView == nil { return false }
        if self.webView!.isLoading == true { return false }
        if didWebViewFinishLoading == false { return false }
        
        return true
    }
    
    /// Process event data for UTAG delivery.
    ///
    /// - Parameters:
    ///   - data: [String:Any] Dictionary of preferrably String or [String] values.
    ///   - completion: Optional completion handler to call when call completes.
    func track(_ data: [String:Any],
               completion: ((_ success:Bool, _ info: [String:Any], _ error: Error?)->Void)?) {
        
        var appendedData = data
        appendedData[TealiumTagManagementKey.dispatchService] = TealiumTagManagementKey.moduleName
        let sanitizedData = TealiumTagManagementUtils.sanitized(dictionary: appendedData)
        guard let encodedPayloadString = TealiumTagManagementUtils.jsonEncode(sanitizedDictionary: sanitizedData) else {
            completion?(false,
                        ["original_payload":appendedData, "sanitized_payload":sanitizedData],
                        TealiumTagManagementError.couldNotJSONEncodeData)
            return
        }
        
        let legacyType = TealiumTagManagementUtils.getLegacyType(fromData: sanitizedData)
        let javascript = "utag.track(\'\(legacyType)\',\(encodedPayloadString))"
        
        var info = [String:Any]()
        info[TealiumTagManagementKey.dispatchService] = TealiumTagManagementKey.moduleName
        info[TealiumTagManagementKey.jsCommand] = javascript
        info += [TealiumTagManagementKey.payload : appendedData]
        if let result = self.webView?.stringByEvaluatingJavaScript(from: javascript) {
            info += [TealiumTagManagementKey.jsResult : result]
        }
        
        // TODO: Check for response code prior to completion return
        completion?(true, info, nil)
        
    }
    
}

extension TealiumTagManagement : UIWebViewDelegate {
    
    public func webView(_ webView: UIWebView, shouldStartLoadWith request: URLRequest, navigationType: UIWebViewNavigationType) -> Bool {
        
        var shouldStart = true
        
        // Broadcast request for any listeners (Remote command module)
        // NOTE: Remote command calls are prefixed with 'tealium://'
        //  Because there is no direct link between Remote Command
        //  and Tag Management, such a call would appear as a failed call
        //  in any web console for this webview.
        let notification = Notification(name: Notification.Name.init(TealiumTagManagementNotificationKey.urlRequestMade),
                                        object: webView,
                                        userInfo: [TealiumTagManagementNotificationKey.urlRequestMade:request])
        NotificationCenter.default.post(notification)
        
        // Look for false from any delegate
        delegates.invoke{ if $0.webView?(webView,
                                         shouldStartLoadWith: request,
                                         navigationType: navigationType) == false {
            shouldStart = false
            }
        }
        
        return shouldStart
    }
    
    public func webViewDidStartLoad(_ webView: UIWebView) {
        
        delegates.invoke{ $0.webViewDidStartLoad?(webView) }
        
    }
    
    public func webView(_ webView: UIWebView, didFailLoadWithError error: Error) {
        
        delegates.invoke{ $0.webView?(webView, didFailLoadWithError: error)}
        if didWebViewFinishLoading == true {
            return
        }
        didWebViewFinishLoading = true
        self.completion?(false, error)
    }
    
    public func webViewDidFinishLoad(_ webView: UIWebView) {
        
        didWebViewFinishLoading = true
        delegates.invoke{ $0.webViewDidFinishLoad?(webView) }
        self.completion?(true, nil)
    }
    
}
#endif

// MARK:
// MARK: UTILS

class TealiumTagManagementUtils {
    
    class func getLegacyType(fromData: [String:Any]) -> String {
        
        var legacyType = "link"
        if fromData[TealiumKey.eventType] as? String == TealiumTrackType.view.description() {
            legacyType = "view"
        }
        return legacyType
    }
    
    class func jsonEncode(sanitizedDictionary:[String:String]) -> String? {
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: sanitizedDictionary,
                                                      options: [])
            let string = NSString(data: jsonData,
                                  encoding: String.Encoding.utf8.rawValue)
            return string as String?
        } catch {
            return nil
        }
    }
    
    class func sanitized(dictionary:[String:Any]) -> [String:String]{
        
        var clean = [String: String]()
        
        for (key, value) in dictionary {
            
            if value is String {
                
                clean[key] = value as? String
                
            } else {
                
                let stringified = "\(value)"
                clean[key] = stringified as String?
            }
            
        }
        
        return clean
        
    }
    
}
