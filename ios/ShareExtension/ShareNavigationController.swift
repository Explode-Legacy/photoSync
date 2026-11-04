import UIKit

/// The share sheet's root: a navigation bar (Cancel / Send) around the list.
@objc(ShareNavigationController)
final class ShareNavigationController: UINavigationController {
  override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
    super.init(rootViewController: ShareViewController())
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setViewControllers([ShareViewController()], animated: false)
  }
}
