//
//  TerminalView.m
//  iSH
//
//  Created by Theodore Dubois on 11/3/17.
//

#import "ScrollbarView.h"
#import "TerminalView.h"
#import "UserPreferences.h"
#import "UIApplication+OpenURL.h"
#import "NSObject+SaneKVO.h"

#import <QuartzCore/QuartzCore.h>

#include <math.h>

struct rowcol {
    int row;
    int col;
};

@interface WeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
@property (weak) id <WKScriptMessageHandler> handler;
@end
@implementation WeakScriptMessageHandler
- (instancetype)initWithHandler:(id <WKScriptMessageHandler>)handler {
    if (self = [super init]) {
        self.handler = handler;
    }
    return self;
}
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.handler userContentController:userContentController didReceiveScriptMessage:message];
}
@end

// One end of a terminal text selection: a bar one row tall with a knob above
// it (start) or below it (end), like UIKit's text selection handles.
@interface LRSelectionHandleView : UIView
@property (nonatomic, readonly) BOOL isStart;
@property (nonatomic) CGFloat lineHeight;
- (instancetype)initAsStart:(BOOL)isStart;
// Top of the handle's row at the selection edge, in superview coordinates.
- (void)placeAtRowTop:(CGPoint)top;
// Centre of that row at the selection edge, in superview coordinates.
- (CGPoint)rowCenter;
@end

static const CGFloat LRHandleWidth = 44;
static const CGFloat LRHandleKnob = 10;
static const CGFloat LRHandleKnobSide = 22;   // touch area beyond the row on the knob's side
static const CGFloat LRHandleBarSide = 8;     // and on the other side

@implementation LRSelectionHandleView {
    UIView *_bar;
    UIView *_knob;
}

- (instancetype)initAsStart:(BOOL)isStart {
    if (self = [super initWithFrame:CGRectZero]) {
        _isStart = isStart;
        _lineHeight = 16;
        _bar = [UIView new];
        _knob = [UIView new];
        _knob.layer.cornerRadius = LRHandleKnob / 2;
        for (UIView *part in @[_bar, _knob]) {
            part.userInteractionEnabled = NO;
            [self addSubview:part];
        }
        self.backgroundColor = UIColor.clearColor;
        self.tintColor = UIColor.systemBlueColor;
        self.isAccessibilityElement = NO;
        self.hidden = YES;
        [self tintColorDidChange];
    }
    return self;
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    _bar.backgroundColor = self.tintColor;
    _knob.backgroundColor = self.tintColor;
}

- (CGFloat)lr_rowInset {
    return self.isStart ? LRHandleKnobSide : LRHandleBarSide;
}

- (void)placeAtRowTop:(CGPoint)top {
    CGFloat above = self.lr_rowInset;
    CGFloat below = self.isStart ? LRHandleBarSide : LRHandleKnobSide;
    CGFloat height = self.lineHeight;
    self.frame = CGRectMake(top.x - LRHandleWidth / 2, top.y - above, LRHandleWidth, above + height + below);
    CGFloat middle = LRHandleWidth / 2;
    _bar.frame = CGRectMake(middle - 1, above, 2, height);
    CGFloat knobY = self.isStart ? above - LRHandleKnob + 1 : above + height - 1;
    _knob.frame = CGRectMake(middle - LRHandleKnob / 2, knobY, LRHandleKnob, LRHandleKnob);
}

- (CGPoint)rowCenter {
    return CGPointMake(CGRectGetMidX(self.frame), CGRectGetMinY(self.frame) + self.lr_rowInset + self.lineHeight / 2);
}

@end

// Keep only the system's Copy, Paste and Select All commands. The system
// Paste reads the pasteboard without iOS asking the user for permission.
static NSArray<UIMenuElement *> *LRTerminalEditActions(NSArray<UIMenuElement *> *elements) {
    NSMutableArray<UIMenuElement *> *kept = [NSMutableArray array];
    for (UIMenuElement *element in elements) {
        if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *menu = (UIMenu *)element;
            NSArray<UIMenuElement *> *children = LRTerminalEditActions(menu.children);
            if (children.count > 0)
                [kept addObject:[menu menuByReplacingChildren:children]];
        } else if ([element isKindOfClass:UICommand.class]) {
            SEL action = ((UICommand *)element).action;
            if (action == @selector(copy:) || action == @selector(paste:) || action == @selector(selectAll:))
                [kept addObject:element];
        }
    }
    return kept;
}

@interface TerminalView () <UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate>

@property (nonatomic) NSMutableArray<UIKeyCommand *> *keyCommands;
@property ScrollbarView *scrollbarView;
@property (nonatomic) BOOL terminalFocused;
@property (nonatomic) BOOL updatingTerminalScroll;
@property UIEditMenuInteraction *terminalEditMenu API_AVAILABLE(ios(16.0));

// Touch interaction (xterm renderer): taps focus, fingers scroll, a long
// press selects, handles adjust the selection.
@property UITapGestureRecognizer *focusTap;
@property UILongPressGestureRecognizer *selectionPress;
@property UIPanGestureRecognizer *wheelPan;
@property UIPanGestureRecognizer *pointerSelectPan;
@property LRSelectionHandleView *startHandle;
@property LRSelectionHandleView *endHandle;
@property (nonatomic) BOOL hasTerminalSelection;
@property CGRect selectionBounds;  // in self; CGRectNull when nothing selected is visible
@property BOOL selectionGestureActive;
@property BOOL selectionMenuVisible;
@property BOOL menuVisibleAtTouchDown;
@property BOOL menuAfterScroll;
@property CGPoint handleGrabOffset;
@property BOOL alternateBuffer;
@property CGPoint wheelPoint;
@property CGFloat wheelResidual;
@property CGFloat wheelVelocity;
@property CFTimeInterval wheelTimestamp;
@property CADisplayLink *wheelMomentum;
@property CGSize cellSize;

@property (nullable) NSString *markedText;
@property (nullable) NSString *selectedText;
@property UITextRange *markedRange;
@property UITextRange *selectedRange;

@property struct rowcol floatingCursor;
@property CGSize floatingCursorSensitivity;
@property CGSize actualFloatingCursorSensitivity;

@end

static NSString *LRTerminalBackground(NSString *hex) {
    // LinuxRunner's terminal: true black for dark themes (default on).
    id setting = [NSUserDefaults.standardUserDefaults objectForKey:@"LinuxRunnerTerminal.trueBlack"];
    if (setting && ![setting boolValue]) return hex;
    UIColor *c = [[UIColor alloc] ish_initWithHexString:hex]; CGFloat w = 1;
    if ([c getWhite:&w alpha:NULL] && w < 0.3) return @"#000000";
    CGFloat r = 1, g = 1, b = 1; if ([c getRed:&r green:&g blue:&b alpha:NULL] && (r + g + b) / 3 < 0.3) return @"#000000";
    return hex;
}
@implementation TerminalView
@synthesize inputDelegate;
@synthesize tokenizer;
@synthesize canBecomeFirstResponder;

- (void)awakeFromNib {
    [super awakeFromNib];
    self.inputAssistantItem.leadingBarButtonGroups = @[];
    self.inputAssistantItem.trailingBarButtonGroups = @[];

    ScrollbarView *scrollbarView = self.scrollbarView = [[ScrollbarView alloc] initWithFrame:self.bounds];
    scrollbarView.delegate = self;
    scrollbarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollbarView.bounces = NO;
    scrollbarView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.clipsToBounds = YES;
    [self addSubview:scrollbarView];
    self.selectionBounds = CGRectNull;
#if USE_XTERM_RENDERER
    [self installTouchInteractions];
#endif

    UserPreferences *prefs = UserPreferences.shared;
    [prefs observe:@[@"capsLockMapping", @"optionMapping", @"backtickMapEscape", @"overrideControlSpace"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_keyCommands = nil;
        });
    }];
    [prefs observe:@[@"colorScheme", @"fontFamily", @"fontSize", @"theme", @"cursorStyle", @"blinkCursor"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyle];
        });
    }];

    self.markedRange = [UITextRange new];
    self.selectedRange = [UITextRange new];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:UIApplication.sharedApplication];
    [center addObserver:self
               selector:@selector(applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification
                 object:UIApplication.sharedApplication];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.terminal = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == _terminal) {
        if (_terminal.loaded) {
            [self installTerminalView];
            [self _updateStyle];
            [self refreshTerminalInteractionState];
        }
    }
}

static NSString *const HANDLERS[] = {@"syncFocus", @"focus", @"newScrollHeight", @"newScrollTop", @"openLink", @"selectionChanged", @"selectionGeometry", @"bufferType"};

- (void)setTerminal:(Terminal *)terminal {
    if (_terminal) {
        [_terminal removeObserver:self forKeyPath:@"loaded"];
        [self uninstallTerminalView];
    }

    _terminal = terminal;
    self.selectedText = nil;
    [self resetTerminalInteractionState];
    if (_terminal == nil)
        return;
    [self _updateStyle];
    [_terminal addObserver:self forKeyPath:@"loaded" options:NSKeyValueObservingOptionInitial context:nil];
    [self installTerminalView];
    [self refreshTerminalInteractionState];
}

- (void)installTerminalView {
    UIView *superview = self.terminal.webView.superview;
    if (superview != nil) {
        NSAssert(superview == self.scrollbarView, @"installing terminal that is already installed elsewhere");
        return;
    }

    WKWebView *webView = _terminal.webView;
    if (_terminal.loaded)
        _terminal.enableVoiceOverAnnounce = YES;
    webView.scrollView.scrollEnabled = NO;
    webView.scrollView.delaysContentTouches = NO;
    webView.scrollView.canCancelContentTouches = NO;
    webView.scrollView.panGestureRecognizer.enabled = NO;
    id <WKScriptMessageHandler> handler = [[WeakScriptMessageHandler alloc] initWithHandler:self];
    for (int i = 0; i < sizeof(HANDLERS)/sizeof(HANDLERS[0]); i++) {
        [webView.configuration.userContentController addScriptMessageHandler:handler name:HANDLERS[i]];
    }
    webView.frame = self.bounds;
    self.opaque = webView.opaque = NO;
    webView.backgroundColor = UIColor.clearColor;
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    self.scrollbarView.contentView = webView;
    [self.scrollbarView addSubview:webView];
}

- (void)uninstallTerminalView {
    [self resetTerminalInteractionState];
    // remove old terminal
    UIView *superview = _terminal.webView.superview;
    if (superview != self.scrollbarView) {
        NSAssert(superview == nil, @"uninstalling terminal that is installed elsewhere");
        return;
    }

    [_terminal.webView removeFromSuperview];
    self.scrollbarView.contentView = nil;
    for (int i = 0; i < sizeof(HANDLERS)/sizeof(HANDLERS[0]); i++) {
        [_terminal.webView.configuration.userContentController removeScriptMessageHandlerForName:HANDLERS[i]];
    }
    _terminal.enableVoiceOverAnnounce = NO;
}

#pragma mark Styling

- (void)_updateStyle {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    UserPreferences *prefs = [UserPreferences shared];
    Palette *palette = prefs.palette;
    if (self.overrideAppearance != OverrideAppearanceNone) {
        palette = self.overrideAppearance == OverrideAppearanceLight ? prefs.theme.lightPalette : prefs.theme.darkPalette;
    }
    NSString *background = LRTerminalBackground(palette.backgroundColor);
    UIColor *backgroundColor = [[UIColor alloc] ish_initWithHexString:background];
    self.backgroundColor = backgroundColor;
    self.scrollbarView.backgroundColor = backgroundColor;
    if (_overrideFontSize == prefs.fontSize.doubleValue)
        _overrideFontSize = 0;
    NSMutableDictionary<NSString *, id> *themeInfo = [@{
        @"fontFamily": prefs.fontFamily,
        @"fontSize": @(self.effectiveFontSize),
        @"foregroundColor": palette.foregroundColor,
        @"backgroundColor": background,
        @"cursorColor": palette.cursorColor ?: palette.foregroundColor,
        @"blinkCursor": @(prefs.blinkCursor),
        @"cursorShape": prefs.htermCursorShape,
        @"sharpness": [NSUserDefaults.standardUserDefaults stringForKey:@"LinuxRunnerTerminal.sharpness"] ?: @"sharp",
    } mutableCopy];
    if (palette.colorPaletteOverrides) {
        themeInfo[@"colorPaletteOverrides"] = palette.colorPaletteOverrides;
    }
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:themeInfo options:0 error:nil] encoding:NSUTF8StringEncoding];
    self.terminal.bootstrapStyleJSON = json;
    if (!self.terminal.loaded)
        return;
    [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.updateStyle(%@)", json] completionHandler:^(id result, NSError *error){
        [self updateFloatingCursorSensitivity];
    }];
}

- (void)setOverrideFontSize:(CGFloat)overrideFontSize {
    _overrideFontSize = overrideFontSize;
    [self _updateStyle];
}

- (void)setOverrideAppearance:(enum OverrideAppearance)overrideAppearance {
    _overrideAppearance = overrideAppearance;
    [self _updateStyle];
}

- (CGFloat)effectiveFontSize {
    if (self.overrideFontSize != 0)
        return self.overrideFontSize;
    return UserPreferences.shared.fontSize.doubleValue;
}

#pragma mark Focus and scrolling

- (BOOL)terminalShouldRenderFocused {
    if (self.window == nil)
        return NO;
    if (@available(iOS 13.0, *))
        return self.window.windowScene.activationState == UISceneActivationStateForegroundActive;
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (void)syncTerminalRenderFocus {
    self.terminalFocused = self.terminalShouldRenderFocused;
}

- (void)setTerminalFocused:(BOOL)terminalFocused {
    _terminalFocused = terminalFocused;
    NSString *script = terminalFocused ? @"exports.setFocused(true)" : @"exports.setFocused(false)";
    [self.terminal.webView evaluateJavaScript:script completionHandler:nil];
}

- (BOOL)becomeFirstResponder {
    [self syncTerminalRenderFocus];
    [self reloadInputViews];
    return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder {
    [self syncTerminalRenderFocus];
    return [super resignFirstResponder];
}
- (void)windowDidBecomeKey:(NSNotification *)notif {
    [self syncTerminalRenderFocus];
}
- (void)windowDidResignKey:(NSNotification *)notif {
    [self syncTerminalRenderFocus];
}
- (void)applicationDidBecomeActive:(NSNotification *)notif {
    [self syncTerminalRenderFocus];
}
- (void)applicationWillResignActive:(NSNotification *)notif {
    self.terminalFocused = NO;
}

- (IBAction)loseFocus:(id)sender {
    [self resignFirstResponder];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    if (newWindow == nil) {
        [self stopWheelMomentum];
        [self dismissSelectionMenu];
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.window != nil) {
        [center removeObserver:self
                          name:UIWindowDidBecomeKeyNotification
                        object:self.window];
        [center removeObserver:self
                          name:UIWindowDidResignKeyNotification
                        object:self.window];
    }
    if (newWindow != nil) {
        [center addObserver:self
                   selector:@selector(windowDidBecomeKey:)
                       name:UIWindowDidBecomeKeyNotification
                     object:newWindow];
        [center addObserver:self
                   selector:@selector(windowDidResignKey:)
                       name:UIWindowDidResignKeyNotification
                     object:newWindow];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"syncFocus"]) {
        [self syncTerminalRenderFocus];
    } else if ([message.name isEqualToString:@"focus"]) {
        if (!self.isFirstResponder) {
            [self becomeFirstResponder];
        }
    } else if ([message.name isEqualToString:@"newScrollHeight"]) {
        if (![message.body isKindOfClass:NSNumber.class])
            return;
        CGFloat newHeight = [message.body doubleValue];
        if (!isfinite(newHeight) || newHeight < 0)
            return;
        self.updatingTerminalScroll = YES;
        self.scrollbarView.contentSize = CGSizeMake(0, newHeight);
        self.updatingTerminalScroll = NO;
    } else if ([message.name isEqualToString:@"newScrollTop"]) {
        if (![message.body isKindOfClass:NSNumber.class])
            return;
        CGFloat newOffset = [message.body doubleValue];
        if (!isfinite(newOffset) || newOffset < 0)
            return;
        newOffset = MIN(newOffset, MAX(0, self.scrollbarView.contentSize.height - self.scrollbarView.bounds.size.height));
        if (self.scrollbarView.contentOffset.y == newOffset)
            return;
        self.updatingTerminalScroll = YES;
        [self.scrollbarView setContentOffset:CGPointMake(0, newOffset) animated:NO];
        self.updatingTerminalScroll = NO;
    } else if ([message.name isEqualToString:@"openLink"]) {
        if ([message.body isKindOfClass:NSString.class])
            [UIApplication openURL:message.body];
    } else if ([message.name isEqualToString:@"selectionChanged"]) {
        if ([message.body isKindOfClass:NSString.class])
            self.selectedText = message.body;
    } else if ([message.name isEqualToString:@"selectionGeometry"]) {
        [self applySelectionGeometry:message.body];
    } else if ([message.name isEqualToString:@"bufferType"]) {
        if ([message.body isKindOfClass:NSString.class])
            [self setBufferType:message.body];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Bring the selection menu back once a scroll that hid it settles.
    if (self.menuAfterScroll) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showMenuAfterScroll) object:nil];
        [self performSelector:@selector(showMenuAfterScroll) withObject:nil afterDelay:0.3];
    }
    // Terminal output updates the indicator, not the user's scroll position.
    if (self.updatingTerminalScroll)
        return;
    [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.newScrollTop(%f)", scrollView.contentOffset.y] completionHandler:nil];
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)keyboardAppearance {
    BOOL needsFirstResponderDance = self.isFirstResponder && _keyboardAppearance != keyboardAppearance;
    if (needsFirstResponderDance) {
        [self resignFirstResponder];
    }
    _keyboardAppearance = keyboardAppearance;
    if (needsFirstResponderDance) {
        [self becomeFirstResponder];
    }
    if (keyboardAppearance == UIKeyboardAppearanceLight) {
        self.scrollbarView.indicatorStyle = UIScrollViewIndicatorStyleBlack;
    } else {
        self.scrollbarView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    }
}

#pragma mark Keyboard Input

// implementing these makes a keyboard pop up when this view is first responder

- (void)insertText:(NSString *)text {
    self.markedText = nil;

    if (self.controlKey.highlighted)
        self.controlKey.selected = YES;
    if (self.controlKey.selected) {
        if (!self.controlKey.highlighted)
            self.controlKey.selected = NO;
        if (text.length == 1)
            return [self insertControlChar:[text characterAtIndex:0]];
    }

    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    if (self.altKey.selected && text.length == 1) {
        self.altKey.selected = NO;
        [self.altKey sendActionsForControlEvents:UIControlEventValueChanged];
        text = [@"\x1b" stringByAppendingString:text];
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self.terminal sendInput:data];
}

- (void)insertControlChar:(char)ch {
    if (strchr(controlKeys, ch) != NULL) {
        if (ch == ' ') ch = '\0';
        if (ch == '2') ch = '@';
        if (ch == '6') ch = '^';
        if (ch != '\0')
            ch = toupper(ch) ^ 0x40;
        [self.terminal sendInput:[NSData dataWithBytes:&ch length:1]];
    }
}

- (void)deleteBackward {
    [self insertText:@"\x7f"];
}

- (BOOL)hasText {
    return YES; // it's always ok to send a "delete"
}

#pragma mark IME Input and Selection

- (void)setMarkedText:(nullable NSString *)markedText selectedRange:(NSRange)selectedRange {
    self.markedText = markedText;
}

- (void)unmarkText {
    [self insertText:self.markedText];
}

- (UITextRange *)markedTextRange {
    if (self.markedText != nil)
        return self.markedRange;
    return nil;
}

// The only reason to have this selected range is to prevent the "speak selection" context action from failing to get the current selection and falling back on calling copy:. It doesn't even have to work, it seems...

- (UITextRange *)selectedTextRange {
    return self.selectedRange;
}

- (NSString *)textInRange:(UITextRange *)range {
    if (range == self.markedRange)
        return self.markedText;
    if (range == self.selectedRange)
        return @"";
    return nil;
}

- (id)insertDictationResultPlaceholder {
    return @"";
}
- (void)removeDictationResultPlaceholder:(id)placeholder willInsertResult:(BOOL)willInsertResult {
}

#pragma mark Keyboard Actions

- (void)paste:(id)sender {
    NSString *string = UIPasteboard.generalPasteboard.string;
    if (string.length > 0)
        [self sendPastedText:string];
}

// Pasted text goes to the terminal as one block: newlines become returns,
// wrapped in bracketed-paste markers when the program asked for them (so a
// shell does not run each pasted line as it arrives).
- (void)sendPastedText:(NSString *)text {
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\r"];
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    if (self.terminal.bracketedPaste) {
        text = [text stringByReplacingOccurrencesOfString:@"\x1b[200~" withString:@""];
        text = [text stringByReplacingOccurrencesOfString:@"\x1b[201~" withString:@""];
        text = [NSString stringWithFormat:@"\x1b[200~%@\x1b[201~", text];
    }
    self.markedText = nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0)
        [self.terminal sendInput:data];
}

- (void)copy:(id)sender {
    [self.terminal.webView evaluateJavaScript:@"exports.copy()" completionHandler:^(id result, NSError *error) {
        if (error == nil && [result isKindOfClass:NSString.class] && [result length] > 0)
            UIPasteboard.generalPasteboard.string = result;
    }];
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
#if USE_XTERM_RENDERER
    if (action == @selector(copy:))
        return self.hasTerminalSelection;
    if (action == @selector(selectAll:))
        return self.terminal.loaded;
    if (action == @selector(paste:))
        return UIPasteboard.generalPasteboard.hasStrings;
    if (action == @selector(cut:) || action == @selector(delete:) || action == @selector(select:))
        return NO;
#endif
    return [super canPerformAction:action withSender:sender];
}

- (void)selectAll:(id)sender {
    [self.terminal.webView evaluateJavaScript:@"exports.selectAll?.()" completionHandler:nil];
}

#pragma mark Touch interaction

- (void)installTouchInteractions {
    // Fingers scroll the scrollback; a trackpad or mouse drag selects instead.
    self.scrollbarView.panGestureRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect), @(UITouchTypePencil)];
    [self.scrollbarView.panGestureRecognizer addTarget:self action:@selector(scrollPanChanged:)];

    UILongPressGestureRecognizer *press = self.selectionPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(selectTerminalText:)];
    press.delegate = self;
    [self addGestureRecognizer:press];

    UITapGestureRecognizer *tap = self.focusTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapTerminal:)];
    tap.delegate = self;
    [tap requireGestureRecognizerToFail:press];
    [self addGestureRecognizer:tap];

    // Without scrollback (the alternate screen of less, vim, htop...) the
    // scroll view has nothing to scroll, so a drag turns into wheel steps.
    UIPanGestureRecognizer *wheel = self.wheelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(wheelPanned:)];
    wheel.maximumNumberOfTouches = 1;
    wheel.allowedTouchTypes = @[@(UITouchTypeDirect), @(UITouchTypePencil)];
    wheel.delegate = self;
    [self addGestureRecognizer:wheel];

    UIPanGestureRecognizer *pointer = self.pointerSelectPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pointerSelect:)];
    pointer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
    pointer.delegate = self;
    [self addGestureRecognizer:pointer];

    for (int i = 0; i < 2; i++) {
        LRSelectionHandleView *handle = [[LRSelectionHandleView alloc] initAsStart:i == 0];
        UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragSelectionHandle:)];
        drag.maximumNumberOfTouches = 1;
        [handle addGestureRecognizer:drag];
        UITapGestureRecognizer *showMenu = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapSelectionHandle:)];
        [showMenu requireGestureRecognizerToFail:drag];
        [handle addGestureRecognizer:showMenu];
        [self addSubview:handle];
        if (i == 0)
            self.startHandle = handle;
        else
            self.endHandle = handle;
    }

    if (@available(iOS 16.0, *)) {
        self.terminalEditMenu = [[UIEditMenuInteraction alloc] initWithDelegate:self];
        [self addInteraction:self.terminalEditMenu];
    }
}

// WebKit would take touches on the page for itself (and its touch handling
// keeps the scroll view from panning), so touches stop at the scroll view and
// the gestures above handle them. Hover and scroll-wheel events still reach
// the page.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
#if USE_XTERM_RENDERER
    UIView *page = self.scrollbarView.contentView;
    if (event != nil && event.type == UIEventTypeTouches && hit != nil && page != nil && [hit isDescendantOfView:page])
        return self.scrollbarView;
#endif
    return hit;
}

- (void)evaluateTerminalScript:(NSString *)script {
    if (self.terminal.loaded)
        [self.terminal.webView evaluateJavaScript:script completionHandler:nil];
}

- (void)refreshTerminalInteractionState {
#if USE_XTERM_RENDERER
    if (!self.terminal.loaded)
        return;
    __weak TerminalView *weakSelf = self;
    [self.terminal.webView evaluateJavaScript:@"exports.bufferType?.()" completionHandler:^(id result, NSError *error) {
        if ([result isKindOfClass:NSString.class])
            [weakSelf setBufferType:result];
    }];
    [self.terminal.webView evaluateJavaScript:@"exports.selectionGeometry?.()" completionHandler:^(id result, NSError *error) {
        if (error == nil)
            [weakSelf applySelectionGeometry:result];
    }];
#endif
}

- (void)resetTerminalInteractionState {
    [self stopWheelMomentum];
    [self dismissSelectionMenu];
    self.menuAfterScroll = NO;
    self.selectionGestureActive = NO;
    self.alternateBuffer = NO;
    self.scrollbarView.scrollEnabled = YES;
    self.hasTerminalSelection = NO;
    self.selectionBounds = CGRectNull;
    self.startHandle.hidden = YES;
    self.endHandle.hidden = YES;
}

- (void)setBufferType:(NSString *)type {
    self.alternateBuffer = [type isEqualToString:@"alternate"];
    if (!self.alternateBuffer)
        [self stopWheelMomentum];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    // The selection handles have their own gestures.
    if ([touch.view isKindOfClass:LRSelectionHandleView.class])
        return NO;
    [self stopWheelMomentum];
    if (gestureRecognizer == self.focusTap)
        self.menuVisibleAtTouchDown = self.isSelectionMenuShowing;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.wheelPan) {
        if (!self.alternateBuffer || self.selectionGestureActive || !self.terminal.loaded)
            return NO;
        CGPoint velocity = [self.wheelPan velocityInView:self];
        return fabs(velocity.y) >= fabs(velocity.x);
    }
    if (gestureRecognizer == self.selectionPress || gestureRecognizer == self.pointerSelectPan)
        return self.terminal.loaded;
    return [super gestureRecognizerShouldBegin:gestureRecognizer];
}

- (void)tapTerminal:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized)
        return;
    // Like a text view: the first tap only drops the selection or menu.
    if (self.hasTerminalSelection) {
        [self clearTerminalSelection];
        return;
    }
    if (self.menuVisibleAtTouchDown) {
        [self dismissSelectionMenu];
        return;
    }
    if (!self.isFirstResponder)
        [self becomeFirstResponder];
}

- (void)clearTerminalSelection {
    [self dismissSelectionMenu];
    [self evaluateTerminalScript:@"exports.clearSelection?.()"];
    [self applySelectionGeometry:nil];
}

- (void)beginSelectionInteraction {
    [self stopWheelMomentum];
    [self dismissSelectionMenu];
    self.menuAfterScroll = NO;
    self.selectionGestureActive = YES;
    self.scrollbarView.scrollEnabled = NO;
}

- (void)finishSelectionInteractionAt:(CGPoint)point showMenu:(BOOL)showMenu {
    self.selectionGestureActive = NO;
    self.scrollbarView.scrollEnabled = YES;
    if (showMenu)
        [self presentSelectionMenuAt:point];
}

- (void)selectTerminalText:(UILongPressGestureRecognizer *)gesture {
    if (!self.terminal.loaded)
        return;
    CGPoint point = [gesture locationInView:self.terminal.webView];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            [self beginSelectionInteraction];
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            [self evaluateTerminalScript:[NSString stringWithFormat:@"exports.selectWordAt(%f,%f)", point.x, point.y]];
            break;
        case UIGestureRecognizerStateChanged:
            [self evaluateTerminalScript:[NSString stringWithFormat:@"exports.extendSelection(%f,%f)", point.x, point.y]];
            break;
        case UIGestureRecognizerStateEnded:
            [self finishSelectionInteractionAt:[gesture locationInView:self] showMenu:YES];
            break;
        default:
            [self finishSelectionInteractionAt:CGPointZero showMenu:NO];
            break;
    }
}

- (void)pointerSelect:(UIPanGestureRecognizer *)pan {
    if (!self.terminal.loaded)
        return;
    WKWebView *webView = self.terminal.webView;
    CGPoint point = [pan locationInView:webView];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint moved = [pan translationInView:webView];
            [self beginSelectionInteraction];
            [self evaluateTerminalScript:[NSString stringWithFormat:@"exports.beginSelection(%f,%f);exports.extendSelection(%f,%f)",
                                          point.x - moved.x, point.y - moved.y, point.x, point.y]];
            break;
        }
        case UIGestureRecognizerStateChanged:
            [self evaluateTerminalScript:[NSString stringWithFormat:@"exports.extendSelection(%f,%f)", point.x, point.y]];
            break;
        default:
            // A pointer shows the menu on secondary click, as text views do.
            [self finishSelectionInteractionAt:CGPointZero showMenu:NO];
            break;
    }
}

- (void)dragSelectionHandle:(UIPanGestureRecognizer *)pan {
    LRSelectionHandleView *handle = (LRSelectionHandleView *)pan.view;
    CGPoint finger = [pan locationInView:self];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            [self beginSelectionInteraction];
            CGPoint center = handle.rowCenter;
            self.handleGrabOffset = CGPointMake(center.x - finger.x, center.y - finger.y);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint target = CGPointMake(finger.x + self.handleGrabOffset.x, finger.y + self.handleGrabOffset.y);
            CGPoint page = [self convertPoint:target toView:self.terminal.webView];
            [self evaluateTerminalScript:[NSString stringWithFormat:@"exports.dragSelectionHandle('%@',%f,%f)",
                                          handle.isStart ? @"start" : @"end", page.x, page.y]];
            break;
        }
        case UIGestureRecognizerStateEnded:
            [self finishSelectionInteractionAt:finger showMenu:YES];
            break;
        default:
            [self finishSelectionInteractionAt:finger showMenu:NO];
            break;
    }
}

- (void)tapSelectionHandle:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized)
        [self presentSelectionMenuAt:[tap locationInView:self]];
}

// Geometry from exports.selectionGeometry(): row tops at both selection
// edges and the visible bounds, in web view coordinates; null when nothing
// is selected.
- (void)applySelectionGeometry:(id)geometry {
    NSDictionary *info = [geometry isKindOfClass:NSDictionary.class] ? geometry : nil;
    WKWebView *webView = self.scrollbarView.contentView == nil ? nil : self.terminal.webView;
    id lineHeightValue = info[@"lineHeight"];
    CGFloat lineHeight = [lineHeightValue isKindOfClass:NSNumber.class] ? [lineHeightValue doubleValue] : 0;
    if (!isfinite(lineHeight) || lineHeight <= 0 || webView == nil)
        info = nil;

    BOOL hadSelection = self.hasTerminalSelection;
    self.hasTerminalSelection = info != nil;
    if (info == nil) {
        self.selectionBounds = CGRectNull;
        self.startHandle.hidden = YES;
        self.endHandle.hidden = YES;
        if (hadSelection && !self.selectionGestureActive)
            [self dismissSelectionMenu];
        return;
    }
    [self placeHandle:self.startHandle at:info[@"start"] lineHeight:lineHeight webView:webView];
    [self placeHandle:self.endHandle at:info[@"end"] lineHeight:lineHeight webView:webView];

    CGRect bounds = CGRectNull;
    NSDictionary *box = [info[@"bounds"] isKindOfClass:NSDictionary.class] ? info[@"bounds"] : nil;
    NSNumber *x = box[@"x"], *y = box[@"y"], *width = box[@"width"], *height = box[@"height"];
    if ([x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] &&
        [width isKindOfClass:NSNumber.class] && [height isKindOfClass:NSNumber.class]) {
        CGRect pageRect = CGRectMake(x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue);
        if (isfinite(pageRect.origin.x) && isfinite(pageRect.origin.y) && isfinite(pageRect.size.width) && isfinite(pageRect.size.height))
            bounds = [webView convertRect:pageRect toView:self];
    }
    self.selectionBounds = bounds;
}

- (void)placeHandle:(LRSelectionHandleView *)handle at:(id)edge lineHeight:(CGFloat)lineHeight webView:(WKWebView *)webView {
    NSDictionary *info = [edge isKindOfClass:NSDictionary.class] ? edge : nil;
    NSNumber *x = info[@"x"], *y = info[@"y"], *visible = info[@"visible"];
    BOOL show = [x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] &&
        [visible isKindOfClass:NSNumber.class] && visible.boolValue && isfinite(x.doubleValue) && isfinite(y.doubleValue);
    handle.hidden = !show;
    if (!show)
        return;
    handle.lineHeight = lineHeight;
    [handle placeAtRowTop:[webView convertPoint:CGPointMake(x.doubleValue, y.doubleValue) toView:self]];
}

#pragma mark Selection menu

- (BOOL)isSelectionMenuShowing {
    if (@available(iOS 16.0, *))
        return self.selectionMenuVisible;
    return UIMenuController.sharedMenuController.menuVisible;
}

// Present after the page has applied queued selection changes, so the menu
// is placed against the final selection.
- (void)presentSelectionMenuAt:(CGPoint)point {
    if (!self.terminal.loaded)
        return;
    __weak TerminalView *weakSelf = self;
    [self.terminal.webView evaluateJavaScript:@"exports.selectionGeometry?.()" completionHandler:^(id result, NSError *error) {
        TerminalView *view = weakSelf;
        if (view == nil || view.selectionGestureActive || view.window == nil)
            return;
        if (error == nil)
            [view applySelectionGeometry:result];
        [view showEditMenuAt:point];
    }];
}

- (void)showEditMenuAt:(CGPoint)point {
    CGRect bounds = self.selectionBounds;
    CGPoint source = CGRectIsNull(bounds) ? point : CGPointMake(CGRectGetMidX(bounds), CGRectGetMinY(bounds));
    if (@available(iOS 16.0, *)) {
        [self.terminalEditMenu presentEditMenuWithConfiguration:[UIEditMenuConfiguration configurationWithIdentifier:nil sourcePoint:source]];
    } else {
        // UIMenuController only shows for the first responder.
        if (!self.isFirstResponder)
            [self becomeFirstResponder];
        CGRect target = CGRectIsNull(bounds) ? CGRectMake(source.x, source.y, 1, 1) : bounds;
        [UIMenuController.sharedMenuController showMenuFromView:self rect:target];
    }
}

- (void)dismissSelectionMenu {
    if (@available(iOS 16.0, *)) {
        [self.terminalEditMenu dismissMenu];
    } else if (UIMenuController.sharedMenuController.menuVisible) {
        [UIMenuController.sharedMenuController hideMenuFromView:self];
    }
    self.selectionMenuVisible = NO;
}

- (void)scrollPanChanged:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan && self.hasTerminalSelection && self.isSelectionMenuShowing) {
        [self dismissSelectionMenu];
        self.menuAfterScroll = YES;
    }
}

- (void)showMenuAfterScroll {
    if (!self.menuAfterScroll || self.scrollbarView.isTracking)
        return;
    self.menuAfterScroll = NO;
    if (self.hasTerminalSelection && !self.selectionGestureActive)
        [self presentSelectionMenuAt:CGPointZero];
}

- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction menuForConfiguration:(UIEditMenuConfiguration *)configuration suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions API_AVAILABLE(ios(16.0)) {
    NSArray<UIMenuElement *> *actions = LRTerminalEditActions(suggestedActions);
    if (actions.count > 0)
        return [UIMenu menuWithChildren:actions];
    // Fallback if the system offered none. A custom Paste can make iOS ask
    // for pasteboard permission.
    __weak TerminalView *view = self;
    NSMutableArray<UIMenuElement *> *fallback = [NSMutableArray array];
    if (self.hasTerminalSelection)
        [fallback addObject:[UIAction actionWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *action) { [view copy:nil]; }]];
    if (UIPasteboard.generalPasteboard.hasStrings)
        [fallback addObject:[UIAction actionWithTitle:@"Paste" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(UIAction *action) { [view paste:nil]; }]];
    [fallback addObject:[UIAction actionWithTitle:@"Select All" image:nil identifier:nil handler:^(UIAction *action) { [view selectAll:nil]; }]];
    return [UIMenu menuWithChildren:fallback];
}

- (CGRect)editMenuInteraction:(UIEditMenuInteraction *)interaction targetRectForConfiguration:(UIEditMenuConfiguration *)configuration API_AVAILABLE(ios(16.0)) {
    return self.selectionBounds;
}

- (void)editMenuInteraction:(UIEditMenuInteraction *)interaction willPresentMenuForConfiguration:(UIEditMenuConfiguration *)configuration animator:(id<UIEditMenuInteractionAnimating>)animator API_AVAILABLE(ios(16.0)) {
    self.selectionMenuVisible = YES;
}

- (void)editMenuInteraction:(UIEditMenuInteraction *)interaction willDismissMenuForConfiguration:(UIEditMenuConfiguration *)configuration animator:(id<UIEditMenuInteractionAnimating>)animator API_AVAILABLE(ios(16.0)) {
    self.selectionMenuVisible = NO;
}

#pragma mark Alternate screen scrolling

- (CGFloat)terminalLineHeight {
    if (self.cellSize.height > 0)
        return self.cellSize.height;
    return MAX(self.effectiveFontSize * 1.2, 8);
}

- (void)wheelPanned:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self stopWheelMomentum];
            [self dismissSelectionMenu];
            self.wheelResidual = 0;
            self.wheelPoint = [pan locationInView:self.terminal.webView];
            [self scrollWheelBy:[pan translationInView:self].y];
            [pan setTranslation:CGPointZero inView:self];
            break;
        case UIGestureRecognizerStateChanged:
            [self scrollWheelBy:[pan translationInView:self].y];
            [pan setTranslation:CGPointZero inView:self];
            break;
        case UIGestureRecognizerStateEnded:
            [self startWheelMomentum:[pan velocityInView:self].y];
            break;
        default:
            break;
    }
}

// distance is finger travel in points; content follows the finger, so
// dragging down shows earlier lines (a wheel step up).
- (void)scrollWheelBy:(CGFloat)distance {
    CGFloat lineHeight = self.terminalLineHeight;
    if (!isfinite(distance) || lineHeight <= 0)
        return;
    self.wheelResidual += distance;
    int lines = (int)trunc(self.wheelResidual / lineHeight);
    if (lines == 0)
        return;
    self.wheelResidual -= lines * lineHeight;
    [self evaluateTerminalScript:[NSString stringWithFormat:@"exports.scrollLines?.(%d,%f,%f)", -lines, self.wheelPoint.x, self.wheelPoint.y]];
}

- (void)startWheelMomentum:(CGFloat)velocity {
    [self stopWheelMomentum];
    if (!isfinite(velocity) || fabs(velocity) < 150 || !self.alternateBuffer)
        return;
    self.wheelVelocity = velocity;
    self.wheelTimestamp = 0;
    self.wheelMomentum = [CADisplayLink displayLinkWithTarget:self selector:@selector(wheelMomentumTick:)];
    [self.wheelMomentum addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)wheelMomentumTick:(CADisplayLink *)link {
    if (self.wheelTimestamp == 0) {
        self.wheelTimestamp = link.timestamp;
        return;
    }
    CFTimeInterval elapsed = MIN(link.timestamp - self.wheelTimestamp, 0.1);
    self.wheelTimestamp = link.timestamp;
    [self scrollWheelBy:self.wheelVelocity * elapsed];
    // Decelerate like a scroll view.
    self.wheelVelocity *= pow(UIScrollViewDecelerationRateNormal, elapsed * 1000);
    if (fabs(self.wheelVelocity) < 60 || !self.alternateBuffer || self.window == nil)
        [self stopWheelMomentum];
}

- (void)stopWheelMomentum {
    [self.wheelMomentum invalidate];
    self.wheelMomentum = nil;
}

- (void)clearScrollback:(UIKeyCommand *)command {
    [self.terminal.webView evaluateJavaScript:@"exports.clearScrollback()" completionHandler:nil];
}

#pragma mark Floating cursor

- (void)updateFloatingCursorSensitivity {
    [self.terminal.webView evaluateJavaScript:@"exports.getCharacterSize()" completionHandler:^(NSArray *charSizeRaw, NSError *error) {
        if (error != nil) {
            NSLog(@"error getting character size: %@", error);
            return;
        }
        if (![charSizeRaw isKindOfClass:NSArray.class] || charSizeRaw.count < 2 ||
            ![charSizeRaw[0] isKindOfClass:NSNumber.class] || ![charSizeRaw[1] isKindOfClass:NSNumber.class])
            return;
        CGSize charSize = CGSizeMake([charSizeRaw[0] doubleValue], [charSizeRaw[1] doubleValue]);
        if (!isfinite(charSize.width) || !isfinite(charSize.height) || charSize.width <= 0 || charSize.height <= 0)
            return;
        self.cellSize = charSize;
        double sensitivity = 0.5;
        self.floatingCursorSensitivity = CGSizeMake(charSize.width / sensitivity, charSize.height / sensitivity);
    }];
}

- (struct rowcol)rowcolFromPoint:(CGPoint)point {
    CGSize sensitivity = self.actualFloatingCursorSensitivity;
    return (struct rowcol) {
        .row = (int) (-point.y / sensitivity.height),
        .col = (int) (point.x / sensitivity.width),
    };
}

- (void)beginFloatingCursorAtPoint:(CGPoint)point {
    self.actualFloatingCursorSensitivity = self.floatingCursorSensitivity;
    self.floatingCursor = [self rowcolFromPoint:point];
}

- (void)updateFloatingCursorAtPoint:(CGPoint)point {
    struct rowcol newPos = [self rowcolFromPoint:point];
    int rowDiff = newPos.row - self.floatingCursor.row;
    int colDiff = newPos.col - self.floatingCursor.col;
    NSMutableString *arrows = [NSMutableString string];
    for (int i = 0; i < abs(rowDiff); i++) {
        [arrows appendString:[self.terminal arrow:rowDiff > 0 ? 'A': 'B']];
    }
    for (int i = 0; i < abs(colDiff); i++) {
        [arrows appendString:[self.terminal arrow:colDiff > 0 ? 'C': 'D']];
    }
    [self insertText:arrows];
    self.floatingCursor = newPos;
}

- (void)endFloatingCursor {
    self.floatingCursor = (struct rowcol) {};
}

#pragma mark Keyboard Traits

- (UITextSmartDashesType)smartDashesType API_AVAILABLE(ios(11)) {
    return UITextSmartDashesTypeNo;
}
- (UITextSmartQuotesType)smartQuotesType API_AVAILABLE(ios(11)) {
    return UITextSmartQuotesTypeNo;
}
- (UITextSmartInsertDeleteType)smartInsertDeleteType API_AVAILABLE(ios(11)) {
    return UITextSmartInsertDeleteTypeNo;
}
- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}
- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}
// Apparently required on iOS 15+: https://stackoverflow.com/a/72359764
- (UITextSpellCheckingType)spellCheckingType {
    return UITextSpellCheckingTypeNo;
}

#pragma mark Hardware Keyboard

- (void)handleKeyCommand:(UIKeyCommand *)command {
    NSString *key = command.input;
    if (command.modifierFlags == 0) {
        if ([key isEqualToString:@"`"] && UserPreferences.shared.backtickMapEscape)
            key = UIKeyInputEscape;
        if ([key isEqualToString:UIKeyInputEscape])
            key = @"\x1b";
        else if ([key isEqualToString:UIKeyInputUpArrow])
            key = [self.terminal arrow:'A'];
        else if ([key isEqualToString:UIKeyInputDownArrow])
            key = [self.terminal arrow:'B'];
        else if ([key isEqualToString:UIKeyInputLeftArrow])
            key = [self.terminal arrow:'D'];
        else if ([key isEqualToString:UIKeyInputRightArrow])
            key = [self.terminal arrow:'C'];
        [self insertText:key];
    } else if (command.modifierFlags & UIKeyModifierShift) {
        [self insertText:[key uppercaseString]];
    } else if (command.modifierFlags & UIKeyModifierAlternate) {
        [self insertText:[@"\x1b" stringByAppendingString:key]];
    } else if (command.modifierFlags & UIKeyModifierAlphaShift) {
        [self handleCapsLockWithCommand:command];
    } else if (command.modifierFlags & UIKeyModifierControl || command.modifierFlags & UIKeyModifierAlphaShift) {
        if (key.length == 0)
            return;
        if ([key isEqualToString:@"2"])
            key = @"@";
        else if ([key isEqualToString:@"6"])
            key = @"^";
        else if ([key isEqualToString:@"-"])
            key = @"_";
        [self insertControlChar:[key characterAtIndex:0]];
    }
}

static const char *alphabet = "abcdefghijklmnopqrstuvwxyz";
static const char *controlKeys = "abcdefghijklmnopqrstuvwxyz@^26-=[]\\ ";
static const char *metaKeys = "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./";

- (NSArray<UIKeyCommand *> *)keyCommands {
    if (_keyCommands != nil)
        return _keyCommands;
    _keyCommands = [NSMutableArray new];
    [self addKeys:controlKeys withModifiers:UIKeyModifierControl];
    for (NSString *specialKey in @[UIKeyInputEscape, UIKeyInputUpArrow, UIKeyInputDownArrow,
                                   UIKeyInputLeftArrow, UIKeyInputRightArrow, @"\t"]) {
        [self addKey:specialKey withModifiers:0];
    }
    if (UserPreferences.shared.capsLockMapping != CapsLockMapNone) {
        if (@available(iOS 13, *)); else {
            [self addKeys:controlKeys withModifiers:UIKeyModifierAlphaShift];
            [self addKeys:alphabet withModifiers:0];
            [self addKeys:alphabet withModifiers:UIKeyModifierShift];
            [self addKey:@"" withModifiers:UIKeyModifierAlphaShift]; // otherwise tap of caps lock can switch layouts
        }
    }
    if (UserPreferences.shared.optionMapping == OptionMapEsc) {
        [self addKeys:metaKeys withModifiers:UIKeyModifierAlternate];
    }
    if (UserPreferences.shared.backtickMapEscape) {
        [self addKey:@"`" withModifiers:0];
    }
    [_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"k"
                                                modifierFlags:UIKeyModifierCommand|UIKeyModifierShift
                                                       action:@selector(clearScrollback:)
                                         discoverabilityTitle:@"Clear Scrollback"]];
    return _keyCommands;
}

- (void)addKeys:(const char *)keys withModifiers:(UIKeyModifierFlags)modifiers {
    for (size_t i = 0; keys[i] != '\0'; i++) {
        [self addKey:[NSString stringWithFormat:@"%c", keys[i]] withModifiers:modifiers];
    }
}

- (void)addKey:(NSString *)key withModifiers:(UIKeyModifierFlags)modifiers {
    UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:key
                                                modifierFlags:modifiers
                                                       action:@selector(handleKeyCommand:)];
    if (@available(iOS 15, *)) {
        command.wantsPriorityOverSystemBehavior = YES;
    }
    [_keyCommands addObject:command];
}

- (void)keyCommandTriggered:(UIKeyCommand *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleKeyCommand:sender];
    });
}

- (void)handleCapsLockWithCommand:(UIKeyCommand *)command {
    CapsLockMapping target = UserPreferences.shared.capsLockMapping;
    NSString *newInput = command.input ? command.input : @"";
    UIKeyModifierFlags flags = command.modifierFlags;
    flags ^= UIKeyModifierAlphaShift;
    if(target == CapsLockMapEscape) {
        newInput = UIKeyInputEscape;
    } else if(target == CapsLockMapControl) {
        if([newInput length] == 0) {
            return;
        }
        flags |= UIKeyModifierControl;
    } else {
        return;
    }

    UIKeyCommand *newCommand = [UIKeyCommand keyCommandWithInput:newInput
                                                   modifierFlags:flags
                                                          action:@selector(keyCommandTriggered:)];
    [self handleKeyCommand:newCommand];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (@available(iOS 13.4, *)) {
        UIKey *key = presses.anyObject.key;
        if (UserPreferences.shared.overrideControlSpace &&
            key.keyCode == UIKeyboardHIDUsageKeyboardSpacebar &&
            key.modifierFlags & UIKeyModifierControl) {
            return [self insertControlChar:' '];
        }
    }
    return [super pressesBegan:presses withEvent:event];
}

#pragma mark UITextInput stubs

#if 0
#define LogStub() NSLog(@"%s", __func__)
#else
#define LogStub()
#endif

- (NSWritingDirection)baseWritingDirectionForPosition:(nonnull UITextPosition *)position inDirection:(UITextStorageDirection)direction { LogStub(); return NSWritingDirectionLeftToRight; }
- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(nonnull UITextRange *)range { LogStub(); }
- (UITextPosition *)beginningOfDocument { LogStub(); return nil; }
- (CGRect)caretRectForPosition:(nonnull UITextPosition *)position { LogStub(); return CGRectZero; }
- (nullable UITextRange *)characterRangeAtPoint:(CGPoint)point { LogStub(); return nil; }
- (nullable UITextRange *)characterRangeByExtendingPosition:(nonnull UITextPosition *)position inDirection:(UITextLayoutDirection)direction { LogStub(); return nil; }
- (nullable UITextPosition *)closestPositionToPoint:(CGPoint)point { LogStub(); return nil; }
- (nullable UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(nonnull UITextRange *)range { LogStub(); return nil; }
- (NSComparisonResult)comparePosition:(nonnull UITextPosition *)position toPosition:(nonnull UITextPosition *)other { LogStub(); return NSOrderedSame; }
- (UITextPosition *)endOfDocument { LogStub(); return nil; }
- (CGRect)firstRectForRange:(nonnull UITextRange *)range { LogStub(); return CGRectZero; }
- (NSDictionary<NSAttributedStringKey,id> *)markedTextStyle { LogStub(); return nil; }
- (void)setMarkedTextStyle:(NSDictionary<NSAttributedStringKey,id> *)markedTextStyle { LogStub(); }
- (NSInteger)offsetFromPosition:(nonnull UITextPosition *)from toPosition:(nonnull UITextPosition *)toPosition { LogStub(); return 0; }
- (nullable UITextPosition *)positionFromPosition:(nonnull UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset { LogStub(); return nil; }
- (nullable UITextPosition *)positionFromPosition:(nonnull UITextPosition *)position offset:(NSInteger)offset { LogStub(); return nil; }
- (nullable UITextPosition *)positionWithinRange:(nonnull UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction { LogStub(); return nil; }
- (void)replaceRange:(nonnull UITextRange *)range withText:(nonnull NSString *)text { LogStub(); }
- (void)setSelectedTextRange:(UITextRange *)selectedTextRange { LogStub(); }
- (nonnull NSArray<UITextSelectionRect *> *)selectionRectsForRange:(nonnull UITextRange *)range { LogStub(); return @[]; }
- (nullable UITextRange *)textRangeFromPosition:(nonnull UITextPosition *)fromPosition toPosition:(nonnull UITextPosition *)toPosition { LogStub(); return nil; }

// conforming to UITextInput makes this view default to being an accessibility element, which blocks selecting anything in it
- (BOOL)isAccessibilityElement { return NO; }

@end
