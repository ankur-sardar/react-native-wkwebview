#import "RCTWKWebView.h"

#import "WeakScriptMessageDelegate.h"

#import <UIKit/UIKit.h>

#import <React/RCTAutoInsetsProtocol.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/RCTView.h>
#import <React/UIView+React.h>

#import <objc/runtime.h>

#import "WKWebView+BrowserHack.h"
#import "WKWebView+Highlight.h"

#define LocalizeString(key) (NSLocalizedStringFromTableInBundle(key, @"Localizable", resourceBundle, nil))

// runtime trick to remove WKWebView keyboard default toolbar
// see: http://stackoverflow.com/questions/19033292/ios-7-uiwebview-keyboard-issue/19042279#19042279
@interface _SwizzleHelper : NSObject @end
@implementation _SwizzleHelper
-(id)inputAccessoryView
{
  return nil;
}
@end

@interface RCTWKWebView () <WKNavigationDelegate, RCTAutoInsetsProtocol, WKScriptMessageHandler, WKUIDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler, UIScrollViewDelegate>

@property (nonatomic, copy) RCTDirectEventBlock onLoadingStart;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingFinish;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingError;
@property (nonatomic, copy) RCTDirectEventBlock onShouldStartLoadWithRequest;
@property (nonatomic, copy) RCTDirectEventBlock onShouldCreateNewWindow;
@property (nonatomic, copy) RCTDirectEventBlock onProgress;
@property (nonatomic, copy) RCTDirectEventBlock onMessage;
@property (assign) BOOL sendCookies;

@end

@implementation RCTWKWebView
{
  WKWebView *_webView;
  NSString *_injectedJavaScript;
  BOOL longPress;
  NSBundle* resourceBundle;
  CGPoint lastOffset;
  BOOL decelerating;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  return self = [super initWithFrame:frame];
}

RCT_NOT_IMPLEMENTED(- (instancetype)initWithCoder:(NSCoder *)aDecoder)

- (instancetype)initWithProcessPool:(WKProcessPool *)processPool
{
  if(self = [self initWithFrame:CGRectZero])
  {
    super.backgroundColor = [UIColor clearColor];
    
    NSString* bundlePath = [[NSBundle mainBundle] pathForResource:@"Scripts" ofType:@"bundle"];
    resourceBundle = [NSBundle bundleWithPath:bundlePath];
    
    _automaticallyAdjustContentInsets = YES;
    _contentInset = UIEdgeInsetsZero;
    
    WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
    config.processPool = processPool;
    WKUserContentController* userController = [[WKUserContentController alloc]init];
    [userController addScriptMessageHandler:[[WeakScriptMessageDelegate alloc] initWithDelegate:self] name:@"reactNative"];
    config.userContentController = userController;
    
    _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
    _webView.UIDelegate = self;
    _webView.scrollView.delegate = self;
    _webView.navigationDelegate = self;
    _webView.scrollView.decelerationRate = UIScrollViewDecelerationRateFast;
    lastOffset = _webView.scrollView.contentOffset;
    [_webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];
    [self addSubview:_webView];
    
    UILongPressGestureRecognizer* longGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
    longGesture.delegate = self;
    [_webView addGestureRecognizer:longGesture];
  }
  return self;
}

- (void)longPressed:(UILongPressGestureRecognizer*)sender {
  if (sender.state == UIGestureRecognizerStateBegan) {
    longPress = YES;
    sender.enabled = NO;
    
    NSUInteger touchCount = [sender numberOfTouches];
    if (touchCount) {
      CGPoint point = [sender locationOfTouch:0 inView:sender.view];
      if ([_webView respondsToSelector:@selector(respondToTapAndHoldAtLocation:)]) {
        NSDictionary* urlResult = [_webView respondToTapAndHoldAtLocation:point];
        if (urlResult.allKeys.count == 0) {
          longPress = NO;
        }
        _onMessage(@{@"name":@"reactNative", @"body": @{@"type":@"contextMenu", @"data":urlResult}});
      }
    }
  } else if (sender.state == UIGestureRecognizerStateCancelled) {
    sender.enabled = YES;
  }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
  return YES;
}

- (void)loadRequest:(NSURLRequest *)request
{
  if (request.URL && _sendCookies) {
    NSDictionary *cookies = [NSHTTPCookie requestHeaderFieldsWithCookies:[[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:request.URL]];
    if ([cookies objectForKey:@"Cookie"]) {
      NSMutableURLRequest *mutableRequest = request.mutableCopy;
      [mutableRequest addValue:cookies[@"Cookie"] forHTTPHeaderField:@"Cookie"];
      request = mutableRequest;
    }
  }
  
  [_webView loadRequest:request];
}

- (void)setLockScroll:(LockScroll)lockScroll {
  _lockScroll = lockScroll;
}

- (void)setScrollToTop:(BOOL)scrollToTop {
  _webView.scrollView.scrollsToTop = scrollToTop;
}

-(void)setHideKeyboardAccessoryView:(BOOL)hideKeyboardAccessoryView
{
  if (!hideKeyboardAccessoryView) {
    return;
  }
  
  UIView* subview;
  for (UIView* view in _webView.scrollView.subviews) {
    if([[view.class description] hasPrefix:@"WKContent"])
      subview = view;
  }
  
  if(subview == nil) return;
  
  NSString* name = [NSString stringWithFormat:@"%@_SwizzleHelper", subview.class.superclass];
  Class newClass = NSClassFromString(name);
  
  if(newClass == nil)
  {
    newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
    if(!newClass) return;
    
    Method method = class_getInstanceMethod([_SwizzleHelper class], @selector(inputAccessoryView));
    class_addMethod(newClass, @selector(inputAccessoryView), method_getImplementation(method), method_getTypeEncoding(method));
    
    objc_registerClassPair(newClass);
  }
  
  object_setClass(subview, newClass);
}


- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
  if (_onMessage) {
    _onMessage(@{@"name":message.name, @"body": message.body});
  }
}

- (void)goForward
{
  [_webView goForward];
}

- (void)evaluateJavaScript:(NSString *)javaScriptString
         completionHandler:(void (^)(id, NSError *error))completionHandler
{
  [_webView evaluateJavaScript:javaScriptString completionHandler:completionHandler];
}

- (void)goBack
{
  [_webView goBack];
}

- (void)reload
{
  NSURLRequest *request = [RCTConvert NSURLRequest:self.source];
  if (request.URL && !_webView.URL.absoluteString.length) {
    [self loadRequest:request];
  }
  else {
    [_webView reload];
  }
}

- (void)stopLoading
{
  [_webView stopLoading];
}

- (void)setSource:(NSDictionary *)source
{
  if (![_source isEqualToDictionary:source]) {
    _source = [source copy];
    _sendCookies = [source[@"sendCookies"] boolValue];
    if ([source[@"customUserAgent"] length] != 0 && [_webView respondsToSelector:@selector(setCustomUserAgent:)]) {
      [_webView setCustomUserAgent:source[@"customUserAgent"]];
    }
    
    // Allow loading local files:
    // <WKWebView source={{ file: RNFS.MainBundlePath + '/data/index.html', allowingReadAccessToURL: RNFS.MainBundlePath }} />
    // Only works for iOS 9+. So iOS 8 will simply ignore those two values
    NSString *file = [RCTConvert NSString:source[@"file"]];
    NSString *allowingReadAccessToURL = [RCTConvert NSString:source[@"allowingReadAccessToURL"]];
    
    if (file && [_webView respondsToSelector:@selector(loadFileURL:allowingReadAccessToURL:)]) {
      NSURL *fileURL = [RCTConvert NSURL:file];
      NSURL *baseURL = [RCTConvert NSURL:allowingReadAccessToURL];
      [_webView loadFileURL:fileURL allowingReadAccessToURL:baseURL];
      return;
    }
    
    // Check for a static html source first
    NSString *html = [RCTConvert NSString:source[@"html"]];
    if (html) {
      NSURL *baseURL = [RCTConvert NSURL:source[@"baseUrl"]];
      if (!baseURL) {
        baseURL = [NSURL URLWithString:@"about:blank"];
      }
      [_webView loadHTMLString:html baseURL:baseURL];
      return;
    }
    
    NSURLRequest *request = [RCTConvert NSURLRequest:source];
    // Because of the way React works, as pages redirect, we actually end up
    // passing the redirect urls back here, so we ignore them if trying to load
    // the same url. We'll expose a call to 'reload' to allow a user to load
    // the existing page.
    if ([request.URL isEqual:_webView.URL]) {
      return;
    }
    if (!request.URL) {
      // Clear the webview
      [_webView loadHTMLString:@"" baseURL:nil];
      return;
    }
    [self loadRequest:request];
  }
}

- (void)findInPage:(NSString *)string {
  if (string && string.length > 0) {
    [_webView removeAllHighlights];
    NSInteger results = [_webView highlightAllOccurencesOfString:string];
    [_webView scrollToHighlightTop];
    NSString *resultString = [NSString stringWithFormat:@"%@: %ld",@"Search Results",(long) results];
    UIAlertView *alert = [[UIAlertView alloc]
                          initWithTitle:resultString
                          message: nil
                          delegate: nil
                          cancelButtonTitle:@"OK"
                          otherButtonTitles:nil];
    [alert show];
  }
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  _webView.frame = self.bounds;
}

- (void)setContentInset:(UIEdgeInsets)contentInset
{
  _contentInset = contentInset;
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:NO];
}

- (void)setBackgroundColor:(UIColor *)backgroundColor
{
  CGFloat alpha = CGColorGetAlpha(backgroundColor.CGColor);
  self.opaque = _webView.opaque = _webView.scrollView.opaque = (alpha == 1.0);
  _webView.backgroundColor = _webView.scrollView.backgroundColor = backgroundColor;
}

- (UIColor *)backgroundColor
{
  return _webView.backgroundColor;
}

- (NSMutableDictionary<NSString *, id> *)baseEvent
{
  NSMutableDictionary<NSString *, id> *event = [[NSMutableDictionary alloc] initWithDictionary:@{
                                                                                                 @"url": _webView.URL.absoluteString ?: @"",
                                                                                                 @"loading" : @(_webView.loading),
                                                                                                 @"title": _webView.title,
                                                                                                 @"canGoBack": @(_webView.canGoBack),
                                                                                                 @"canGoForward" : @(_webView.canGoForward),
                                                                                                 @"progress" : @(_webView.estimatedProgress),
                                                                                                 }];
  
  return event;
}

- (void)refreshContentInset
{
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:YES];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
  if ([keyPath isEqualToString:@"estimatedProgress"]) {
    if (!_onProgress) {
      return;
    }
    _onProgress(@{@"progress": [change objectForKey:NSKeyValueChangeNewKey]});
  }
}

- (void)dealloc
{
  @try {
    [_webView removeObserver:self forKeyPath:@"estimatedProgress"];
  }
  @catch (NSException * __unused exception) {}
}

#pragma mark - WKNavigationDelegate methods

- (void)webView:(__unused WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  NSURLRequest *request = navigationAction.request;
  NSURL* url = request.URL;
  NSString* scheme = url.scheme;
  
  BOOL isJSNavigation = [scheme isEqualToString:RCTJSNavigationScheme];
  
  if (longPress) {
    longPress = NO;
    return decisionHandler(WKNavigationActionPolicyCancel);
  }
  
  // skip this for the JS Navigation handler
  if (!isJSNavigation && _onShouldStartLoadWithRequest) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{
                                       @"url": (request.URL).absoluteString,
                                       @"navigationType": @(navigationAction.navigationType)
                                       }];
    if (![self.delegate webView:self
      shouldStartLoadForRequest:event
                   withCallback:_onShouldStartLoadWithRequest]) {
      return decisionHandler(WKNavigationActionPolicyCancel);
    }
  }
  
  if (!navigationAction.targetFrame) {
    // Open a new tab
    return decisionHandler(WKNavigationActionPolicyAllow);
  }
  
  if (_onLoadingStart) {
    // We have this check to filter out iframe requests and whatnot
    BOOL isTopFrame = [url isEqual:request.mainDocumentURL];
    if (isTopFrame) {
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      [event addEntriesFromDictionary: @{
                                         @"url": url.absoluteString,
                                         @"navigationType": @(navigationAction.navigationType)
                                         }];
      _onLoadingStart(event);
    }
  }
  
  if (isJSNavigation) {
    decisionHandler(WKNavigationActionPolicyCancel);
  }
  else {
    decisionHandler(WKNavigationActionPolicyAllow);
  }
}

- (void)webView:(__unused WKWebView *)webView didFailProvisionalNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
  if (_onLoadingError) {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
      // NSURLErrorCancelled is reported when a page has a redirect OR if you load
      // a new URL in the WebView before the previous one came back. We can just
      // ignore these since they aren't real errors.
      // http://stackoverflow.com/questions/1024748/how-do-i-fix-nsurlerrordomain-error-999-in-iphone-3-0-os
      return;
    }
    
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary:@{
                                      @"domain": error.domain,
                                      @"code": @(error.code),
                                      @"description": error.localizedDescription,
                                      }];
    _onLoadingError(event);
  }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(__unused WKNavigation *)navigation
{
  NSString *jsFile = @"_webview";
  
  NSString *jsFilePath = [resourceBundle pathForResource:jsFile ofType:@"js"];
  NSURL *jsURL = [NSURL fileURLWithPath:jsFilePath];
  NSString *javascriptCode = [NSString stringWithContentsOfFile:jsURL.path encoding:NSUTF8StringEncoding error:nil];
  [_webView stringByEvaluatingJavaScriptFromString:javascriptCode];
  if (_injectedJavaScript != nil) {
    [webView evaluateJavaScript:_injectedJavaScript completionHandler:^(id result, NSError *error) {
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      event[@"jsEvaluationValue"] = [NSString stringWithFormat:@"%@", result];
      _onLoadingFinish(event);
    }];
  }
  // we only need the final 'finishLoad' call so only fire the event when we're actually done loading.
  else if (_onLoadingFinish && !webView.loading && ![webView.URL.absoluteString isEqualToString:@"about:blank"]) {
    _onLoadingFinish([self baseEvent]);
  }
  
  [webView evaluateJavaScript:@"document.body.style.webkitTouchCallout='none';" completionHandler:nil];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
  decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler {
  NSString* authMethod = challenge.protectionSpace.authenticationMethod;
  if ([authMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
    @try {
      [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
    } @catch (NSException *exception) {
      NSLog(@"%@", exception.description);
    } @finally {
      completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
  } else if ([authMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]) {
    UIAlertController* alertView = [UIAlertController alertControllerWithTitle:[LocalizeString(@"Login_title") stringByReplacingOccurrencesOfString:@"%s" withString:challenge.protectionSpace.host] message:@"" preferredStyle:UIAlertControllerStyleAlert];
    [alertView addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
      textField.placeholder = LocalizeString(@"Username");
    }];
    [alertView addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
      textField.placeholder = LocalizeString(@"Password");
      textField.secureTextEntry = YES;
    }];
    [alertView addAction:[UIAlertAction actionWithTitle:LocalizeString(@"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
      completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }]];
    
    [alertView addAction:[UIAlertAction actionWithTitle:LocalizeString(@"Login") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
      UITextField *userField = alertView.textFields.firstObject;
      UITextField *passField = alertView.textFields.lastObject;
      NSURLCredential* credential = [NSURLCredential credentialWithUser:userField.text password:passField.text persistence:NSURLCredentialPersistenceForSession];
      @try {
        [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
      } @catch (NSException *exception) {
        NSLog(@"%@", exception.description);
      } @finally {
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
      }
    }]];
    [[[UIApplication sharedApplication].delegate window].rootViewController presentViewController:alertView animated:YES completion:nil];
  }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  CGPoint offset = scrollView.contentOffset;
  CGFloat dy = offset.y - lastOffset.y;
  if (offset.y < 0) dy = 0;
//  CGFloat offsetMin = 0;
//  CGFloat offsetMax = scrollView.contentSize.height - scrollView.frame.size.height;
//  
//  BOOL shoudLockUp = dy < 0 && offset.y < offsetMax && lastOffset.y < offsetMax;
//  BOOL shoudLockDw = dy >= 0 && offset.y >= offsetMin && lastOffset.y >= offsetMin;
  
  NSMutableDictionary<NSString *, id> *event = [self baseEvent];
  [event addEntriesFromDictionary:@{@"contentOffset": @{@"x": @(offset.x),@"y": @(offset.y)}}];
  [event addEntriesFromDictionary:@{@"contentSize": @{@"width" : @(scrollView.contentSize.width), @"height": @(scrollView.contentSize.height)}}];
//  if ((_lockScroll == NoLock) ||
//      (_lockScroll == LockDirectionUp && !shoudLockUp) ||
//      (_lockScroll == LockDirectionDown && !shoudLockDw) ||
//      (_lockScroll == LockDirectionBoth && !shoudLockUp && !shoudLockDw)) {
//    lastOffset = offset;
//  } else {
//    [event addEntriesFromDictionary:@{@"offset": @{@"dx": @(offset.x - lastOffset.x),@"dy": @(dy)}}];
//    [scrollView setContentOffset:lastOffset animated:NO];
//  }
  [event addEntriesFromDictionary:@{@"offset": @{@"dx": @(offset.x - lastOffset.x),@"dy": @(dy)}}];
  lastOffset = offset;
  _onMessage(@{@"name":@"reactNative", @"body": @{@"type":@"onScroll", @"data":event}});
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
  
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView {
  decelerating = YES;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
  decelerating = NO;
}

#pragma mark - WKUIDelegate

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
  UIAlertController *alertController = [UIAlertController alertControllerWithTitle:message message:nil preferredStyle:UIAlertControllerStyleAlert];
  
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Close", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler();
  }]];
  UIViewController *presentingController = RCTPresentedViewController();
  [presentingController presentViewController:alertController animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
  
  // TODO We have to think message to confirm "YES"
  UIAlertController *alertController = [UIAlertController alertControllerWithTitle:message message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    completionHandler(YES);
  }]];
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler(NO);
  }]];
  UIViewController *presentingController = RCTPresentedViewController();
  [presentingController presentViewController:alertController animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler {
  
  UIAlertController *alertController = [UIAlertController alertControllerWithTitle:prompt message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.text = defaultText;
  }];
  
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    NSString *input = ((UITextField *)alertController.textFields.firstObject).text;
    completionHandler(input);
  }]];
  
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler(nil);
  }]];
  UIViewController *presentingController = RCTPresentedViewController();
  [presentingController presentViewController:alertController animated:YES completion:nil];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
  NSString *scheme = navigationAction.request.URL.scheme;
  if ((navigationAction.targetFrame.isMainFrame || _openNewWindowInWebView) && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{
                                       @"url": (navigationAction.request.URL).absoluteString,
                                       @"navigationType": @(navigationAction.navigationType)
                                       }];
    if (![self.delegate webView:self shouldCreateNewWindow:event withCallback:_onShouldCreateNewWindow]) {
      [webView loadRequest:navigationAction.request];
    }
  } else {
    UIApplication *app = [UIApplication sharedApplication];
    NSURL *url = navigationAction.request.URL;
    if ([app canOpenURL:url]) {
      [app openURL:url];
    }
  }
  return nil;
}

#pragma mark - Custom methods for custom context menu

@end
