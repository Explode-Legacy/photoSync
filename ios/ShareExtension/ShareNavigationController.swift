import UIKit

/// The share sheet's root: a navigation bar (Cancel / Send) around the list.
/// No @objc(name): Info.plist names it `$(PRODUCT_MODULE_NAME).ShareNavigationController`,
/// which only matches the default (module-qualified) runtime name.
final class ShareNavigationController: UINavigationController {
  override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
    super.init(rootViewController: ShareViewController())
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setViewControllers([ShareViewController()], animated: false)
  }
}
