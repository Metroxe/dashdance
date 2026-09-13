// macOS launcher: an AppKit window with the disc, a few settings and Play.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#include "mac_launcher.h"
#include "slippi_login.h"

namespace {
void prepare_application() {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  static bool launched = false;
  if (!launched) { [NSApp finishLaunching]; launched = true; }
  [NSApp activateIgnoringOtherApps:YES];
}
}  // namespace

@interface MULauncherWindow : NSObject
@property(nonatomic) host::LauncherSettings* settings;
@property(nonatomic) NSWindow* window;
@property(nonatomic) NSTextField* discName;
@property(nonatomic) NSTextField* discHint;
@property(nonatomic) NSButton* playButton;
@property(nonatomic) NSButton* widescreen;
@property(nonatomic) NSButton* online;
@property(nonatomic) NSSlider* sharpness;
@property(nonatomic, copy) NSString* startupError;
@property(nonatomic) NSTextField* accountLabel;
@property(nonatomic) NSTextField* emailField;
@property(nonatomic) NSSecureTextField* passwordField;
@property(nonatomic) NSButton* signInButton;
@property(nonatomic) NSButton* signOutButton;
@property(nonatomic) NSButton* resetButton;
@property(nonatomic) NSStackView* signInRows;
@property(nonatomic) BOOL busy;
@end

@implementation MULauncherWindow
- (instancetype)initWithSettings:(host::LauncherSettings*)settings error:(NSString*)error {
  self = [super init];
  self.settings = settings;
  self.startupError = error;
  NSRect frame = NSMakeRect(0, 0, 560, 700);
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                              backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"Melee Unlocked";
  self.window.titlebarAppearsTransparent = YES;
  self.window.titleVisibility = NSWindowTitleHidden;
  self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  self.window.backgroundColor = [NSColor colorWithSRGBRed:0.07 green:0.05 blue:0.14 alpha:1];
  [self.window center];

  NSStackView* stack = [[NSStackView alloc] init];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 14;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.window.contentView addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:48],
    [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:36],
    [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-36]]];

  NSTextField* title = [NSTextField labelWithString:@"Melee Unlocked"];
  title.font = [NSFont systemFontOfSize:34 weight:NSFontWeightBold];
  title.textColor = NSColor.whiteColor;
  NSTextField* subtitle = [NSTextField wrappingLabelWithString:@"Super Smash Bros. Melee with Slippi rollback netplay, native on Apple silicon."];
  subtitle.font = [NSFont systemFontOfSize:14];
  subtitle.textColor = [NSColor colorWithWhite:1 alpha:0.7];
  [stack addArrangedSubview:title];
  [stack addArrangedSubview:subtitle];
  [stack setCustomSpacing:26 afterView:subtitle];

  NSBox* card = [self card];
  NSStackView* cardStack = [self stackIn:card];
  [cardStack addArrangedSubview:[self caption:@"GAME DISC"]];
  self.discName = [NSTextField labelWithString:@""];
  self.discName.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
  self.discName.textColor = NSColor.whiteColor;
  self.discName.lineBreakMode = NSLineBreakByTruncatingMiddle;
  self.discHint = [NSTextField wrappingLabelWithString:@""];
  self.discHint.font = [NSFont systemFontOfSize:12];
  self.discHint.textColor = [NSColor colorWithWhite:1 alpha:0.6];
  NSButton* choose = [NSButton buttonWithTitle:@"Choose Disc Image…" target:self action:@selector(chooseDisc)];
  choose.bezelStyle = NSBezelStyleRounded;
  [cardStack addArrangedSubview:self.discName];
  [cardStack addArrangedSubview:self.discHint];
  [cardStack addArrangedSubview:choose];
  [stack addArrangedSubview:card];

  NSBox* accountCard = [self card];
  NSStackView* accountStack = [self stackIn:accountCard];
  [accountStack addArrangedSubview:[self caption:@"SLIPPI ONLINE ACCOUNT"]];
  self.accountLabel = [NSTextField wrappingLabelWithString:@""];
  self.accountLabel.font = [NSFont systemFontOfSize:13];
  self.accountLabel.textColor = NSColor.whiteColor;
  [accountStack addArrangedSubview:self.accountLabel];
  self.signInRows = [[NSStackView alloc] init];
  self.signInRows.orientation = NSUserInterfaceLayoutOrientationVertical;
  self.signInRows.alignment = NSLayoutAttributeLeading;
  self.signInRows.spacing = 6;
  NSStackView* fields = [[NSStackView alloc] init];
  fields.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.emailField = [[NSTextField alloc] init];
  self.emailField.placeholderString = @"Email";
  self.passwordField = [[NSSecureTextField alloc] init];
  self.passwordField.placeholderString = @"Password";
  self.passwordField.target = self; self.passwordField.action = @selector(signIn);
  [self.emailField.widthAnchor constraintEqualToConstant:200].active = YES;
  [self.passwordField.widthAnchor constraintEqualToConstant:160].active = YES;
  self.signInButton = [NSButton buttonWithTitle:@"Sign In" target:self action:@selector(signIn)];
  self.signInButton.bezelStyle = NSBezelStyleRounded;
  [fields addArrangedSubview:self.emailField];
  [fields addArrangedSubview:self.passwordField];
  [fields addArrangedSubview:self.signInButton];
  self.resetButton = [NSButton buttonWithTitle:@"Forgot password · Create an account at slippi.gg" target:self action:@selector(forgotPassword)];
  self.resetButton.bezelStyle = NSBezelStyleInline;
  self.resetButton.bordered = NO;
  self.resetButton.font = [NSFont systemFontOfSize:11];
  self.resetButton.contentTintColor = [NSColor colorWithSRGBRed:0.62 green:0.56 blue:1 alpha:1];
  [self.signInRows addArrangedSubview:fields];
  [self.signInRows addArrangedSubview:self.resetButton];
  [accountStack addArrangedSubview:self.signInRows];
  self.signOutButton = [NSButton buttonWithTitle:@"Sign Out" target:self action:@selector(signOut)];
  self.signOutButton.bezelStyle = NSBezelStyleRounded;
  [accountStack addArrangedSubview:self.signOutButton];
  [stack addArrangedSubview:accountCard];
  [self refreshAccount];

  NSBox* settingsCard = [self card];
  NSStackView* settingsStack = [self stackIn:settingsCard];
  [settingsStack addArrangedSubview:[self caption:@"PLAY"]];
  self.widescreen = [NSButton checkboxWithTitle:@"Widescreen (16:9)" target:nil action:nil];
  self.widescreen.state = settings->widescreen ? NSControlStateValueOn : NSControlStateValueOff;
  self.online = [NSButton checkboxWithTitle:@"Slippi Online" target:nil action:nil];
  self.online.state = settings->online ? NSControlStateValueOn : NSControlStateValueOff;
  NSStackView* sharpRow = [[NSStackView alloc] init];
  sharpRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  NSTextField* sharpLabel = [NSTextField labelWithString:@"Sharpen"];
  sharpLabel.textColor = NSColor.whiteColor;
  self.sharpness = [NSSlider sliderWithValue:settings->sharpness minValue:0 maxValue:1 target:nil action:nil];
  [self.sharpness.widthAnchor constraintEqualToConstant:200].active = YES;
  [sharpRow addArrangedSubview:sharpLabel];
  [sharpRow addArrangedSubview:self.sharpness];
  [settingsStack addArrangedSubview:self.widescreen];
  [settingsStack addArrangedSubview:self.online];
  [settingsStack addArrangedSubview:sharpRow];
  [stack addArrangedSubview:settingsCard];

  NSStackView* buttons = [[NSStackView alloc] init];
  buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  NSTextField* keys = [NSTextField wrappingLabelWithString:@"Keyboard: arrows move · Z attack · X special · C/V jump · Q/W shield · E grab · Return start. GameCube adapters and gamepads work too."];
  keys.font = [NSFont systemFontOfSize:11];
  keys.textColor = [NSColor colorWithWhite:1 alpha:0.5];
  [keys.widthAnchor constraintLessThanOrEqualToConstant:330].active = YES;
  self.playButton = [NSButton buttonWithTitle:@"Play" target:self action:@selector(play)];
  self.playButton.bezelStyle = NSBezelStyleRounded;
  self.playButton.keyEquivalent = @"\r";
  self.playButton.controlSize = NSControlSizeLarge;
  [buttons addArrangedSubview:keys];
  [buttons addArrangedSubview:self.playButton];
  [stack addArrangedSubview:buttons];
  for (NSView* full in @[card, accountCard, settingsCard, buttons]) [full.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
  [self refreshDisc];
  return self;
}
- (NSBox*)card {
  NSBox* box = [[NSBox alloc] init];
  box.boxType = NSBoxCustom;
  box.cornerRadius = 14;
  box.borderWidth = 0;
  box.fillColor = [NSColor colorWithWhite:1 alpha:0.08];
  box.contentViewMargins = NSMakeSize(0, 0);
  return box;
}
- (NSStackView*)stackIn:(NSBox*)box {
  NSStackView* s = [[NSStackView alloc] init];
  s.orientation = NSUserInterfaceLayoutOrientationVertical;
  s.alignment = NSLayoutAttributeLeading;
  s.spacing = 8;
  s.translatesAutoresizingMaskIntoConstraints = NO;
  [box.contentView addSubview:s];
  [NSLayoutConstraint activateConstraints:@[
    [s.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:16], [s.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-16],
    [s.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:16], [s.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-16]]];
  return s;
}
- (NSTextField*)caption:(NSString*)text {
  NSTextField* l = [NSTextField labelWithString:text];
  l.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
  l.textColor = [NSColor colorWithWhite:1 alpha:0.5];
  return l;
}
- (void)refreshAccount {
  slippi::login::Account account;
  const bool own = slippi::login::read_user_file(self.settings->slippi_dir, account);
  const bool launcher = !own && self.settings->account_from_launcher && !self.settings->account_code.empty();
  if (own) {
    self.settings->account_name = account.display_name; self.settings->account_code = account.connect_code;
    self.accountLabel.stringValue = [NSString stringWithFormat:@"Signed in as %s  (%s)", account.display_name.c_str(), account.connect_code.c_str()];
  } else if (launcher) {
    self.accountLabel.stringValue = [NSString stringWithFormat:@"Using your Slippi Launcher login: %s  (%s). Sign in below to use a different account.",
                                     self.settings->account_name.c_str(), self.settings->account_code.c_str()];
  } else {
    self.settings->account_name.clear(); self.settings->account_code.clear();
    self.accountLabel.stringValue = @"Sign in with your Slippi account to play online (or sign in with the Slippi Launcher). Offline play needs no account.";
  }
  self.signInRows.hidden = own;
  self.signOutButton.hidden = !own;
}
- (void)signIn {
  if (self.busy) return;
  std::string email = self.emailField.stringValue.UTF8String, password = self.passwordField.stringValue.UTF8String;
  if (email.empty() || password.empty()) { self.accountLabel.stringValue = @"Enter your Slippi email and password."; return; }
  self.busy = YES; self.signInButton.enabled = NO;
  self.accountLabel.stringValue = @"Signing in…";
  std::string dir = self.settings->slippi_dir;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    slippi::login::Account account; std::string error;
    bool ok = slippi::login::sign_in(email, password, account, error) && slippi::login::write_user_file(dir, account, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.busy = NO; self.signInButton.enabled = YES;
      if (ok) { self.passwordField.stringValue = @""; [self refreshAccount]; }
      else self.accountLabel.stringValue = [NSString stringWithUTF8String:error.c_str()];
    });
  });
}
- (void)forgotPassword {
  std::string email = self.emailField.stringValue.UTF8String;
  if (email.empty()) { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://slippi.gg"]]; return; }
  self.accountLabel.stringValue = @"Sending a password reset email…";
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::string error;
    bool ok = slippi::login::send_password_reset(email, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.accountLabel.stringValue = ok ? @"Password reset email sent. Check your inbox." : [NSString stringWithUTF8String:error.c_str()];
    });
  });
}
- (void)signOut {
  slippi::login::remove_user_file(self.settings->slippi_dir);
  [self refreshAccount];
}
- (void)refreshDisc {
  if (self.settings->iso.empty()) {
    self.discName.stringValue = @"No disc chosen";
    self.discHint.stringValue = self.startupError.length ? self.startupError : @"Choose your Super Smash Bros. Melee NTSC 1.02 image (.iso/.gcm). The game is read from it; nothing from it is included with the app.";
    self.playButton.enabled = NO;
  } else {
    NSString* path = [NSString stringWithUTF8String:self.settings->iso.c_str()];
    self.discName.stringValue = path.lastPathComponent;
    self.discHint.stringValue = [path stringByAbbreviatingWithTildeInPath];
    self.playButton.enabled = YES;
  }
}
- (void)chooseDisc {
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"Choose Disc Image";
  panel.prompt = @"Choose";
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK) return;
  self.settings->iso = std::string(panel.URL.fileSystemRepresentation);
  self.startupError = nil;
  [self refreshDisc];
}
- (void)play {
  self.settings->widescreen = self.widescreen.state == NSControlStateValueOn;
  self.settings->online = self.online.state == NSControlStateValueOn;
  self.settings->sharpness = (float)self.sharpness.doubleValue;
  [NSApp stopModalWithCode:NSModalResponseOK];
}
@end

namespace host {
void mac_show_error(const std::string& title, const std::string& detail) {
  @autoreleasepool {
    prepare_application();
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithUTF8String:title.c_str()];
    alert.informativeText = [NSString stringWithUTF8String:detail.c_str()];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
  }
}

bool launcher_run(LauncherSettings& settings, const std::string& error) {
  @autoreleasepool {
    prepare_application();
    MULauncherWindow* launcher = [[MULauncherWindow alloc] initWithSettings:&settings
                                                                       error:error.empty() ? nil : [NSString stringWithUTF8String:error.c_str()]];
    [launcher.window makeKeyAndOrderFront:nil];
    NSModalResponse response = [NSApp runModalForWindow:launcher.window];
    [launcher.window orderOut:nil];
    return response == NSModalResponseOK;
  }
}
}  // namespace host
