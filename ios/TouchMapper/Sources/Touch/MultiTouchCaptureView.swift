//
//  MultiTouchCaptureView.swift
//  TouchMapper iOS
//
//  用 UIViewRepresentable 包一层真正能接多点触摸的 UIView。
//  SwiftUI 的 DragGesture 只给单指、还会被滚动容器抢走，拿不到 10 指；
//  只有重写 UIResponder 的 touchesBegan/Moved/Ended/Cancelled 才有完整的触点集合。
//

import SwiftUI
import UIKit

struct MultiTouchCaptureView: UIViewRepresentable {

    /// 每个触点变化时回调：(contactId, 归一化坐标)
    var onTouchBegan: (Int, CGPoint) -> Void
    var onTouchMoved: (Int, CGPoint) -> Void
    var onTouchEnded: (Int, CGPoint) -> Void
    var onTouchCancelled: (Int, CGPoint) -> Void
    var onSizeChanged: (CGSize) -> Void

    func makeUIView(context: Context) -> TouchCaptureUIView {
        let view = TouchCaptureUIView()
        view.isMultipleTouchEnabled = true
        view.isExclusiveTouch = false
        view.backgroundColor = .clear
        view.onBegan = onTouchBegan
        view.onMoved = onTouchMoved
        view.onEnded = onTouchEnded
        view.onCancelled = onTouchCancelled
        view.onSizeChanged = onSizeChanged
        return view
    }

    func updateUIView(_ uiView: TouchCaptureUIView, context: Context) {
        uiView.onBegan = onTouchBegan
        uiView.onMoved = onTouchMoved
        uiView.onEnded = onTouchEnded
        uiView.onCancelled = onTouchCancelled
        uiView.onSizeChanged = onSizeChanged
    }
}

final class TouchCaptureUIView: UIView {

    var onBegan: ((Int, CGPoint) -> Void)?
    var onMoved: ((Int, CGPoint) -> Void)?
    var onEnded: ((Int, CGPoint) -> Void)?
    var onCancelled: ((Int, CGPoint) -> Void)?
    var onSizeChanged: ((CGSize) -> Void)?

    private var contactIds: [ObjectIdentifier: Int] = [:]
    private var nextLocalId: Int = 0
    private let maxContacts = TouchMapperProtocol.maxContacts

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onSizeChanged?(bounds.size)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 让触摸投递不走系统延迟合并，压低输入延迟。这是 UIView 自己的方法。
        requestUnbufferedDispatch(for: .allTouchTypes)
    }

    // MARK: - 触点映射

    private func id(for touch: UITouch) -> Int? {
        let key = ObjectIdentifier(touch)
        if let existing = contactIds[key] { return existing }
        guard contactIds.count < maxContacts else { return nil }
        for _ in 0..<maxContacts {
            let candidate = nextLocalId
            nextLocalId = (nextLocalId + 1) % maxContacts
            if !contactIds.values.contains(candidate) {
                contactIds[key] = candidate
                return candidate
            }
        }
        return nil
    }

    private func releaseId(for touch: UITouch) {
        contactIds.removeValue(forKey: ObjectIdentifier(touch))
    }

    private func point(_ touch: UITouch) -> CGPoint {
        touch.location(in: self)
    }

    // MARK: - 触摸回调

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let cid = id(for: touch) else { continue }
            onBegan?(cid, point(touch))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let cid = contactIds[ObjectIdentifier(touch)] else { continue }
            onMoved?(cid, point(touch))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let cid = contactIds[ObjectIdentifier(touch)] else { continue }
            onEnded?(cid, point(touch))
            releaseId(for: touch)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let cid = contactIds[ObjectIdentifier(touch)] else { continue }
            onCancelled?(cid, point(touch))
            releaseId(for: touch)
        }
    }
}
