import UIKit

extension UIApplication {
    func topMostViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.windows.first { $0.isKeyWindow }
        return keyWindow?.rootViewController?.topMostViewController()
    }
}

extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController {
            return presented.topMostViewController()
        }
        
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topMostViewController() ?? navigation
        }
        
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topMostViewController() ?? tab
        }
        
        return self
    }
} 