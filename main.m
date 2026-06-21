#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UINavigationController *nav = [[UINavigationController alloc]
		initWithRootViewController:[[NSClassFromString(@"SPTMTestViewController") alloc] init]];
	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];
	return YES;
}
@end

int main(int argc, char *argv[]) {
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
	}
}
