import SwiftUI

struct ToastHelper {
    static func show(_ message: String, isError: Bool = false) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let w = scene.windows.first else { return }
        let t = UILabel()
        t.text = message
        t.textColor = .white
        t.backgroundColor = isError ? UIColor(Color(hex: "E74C3C")) : UIColor(Color(hex: "1C1C1E"))
        t.textAlignment = .center
        t.font = .systemFont(ofSize: 14)
        t.layer.cornerRadius = 10
        t.clipsToBounds = true
        t.alpha = 0
        t.frame = CGRect(x: 20, y: w.frame.height - 120, width: w.frame.width - 40, height: 44)
        w.addSubview(t)
        UIView.animate(withDuration: 0.3) { t.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 2) { t.alpha = 0 } completion: { _ in t.removeFromSuperview() }
    }
}
