//
//  DraggableCommandEditor.swift
//  PathDock
//
//  NSTextView 를 SwiftUI 에 래핑한 명령어 편집기.
//  - fileURL 드롭을 받아 onDropFile 콜백을 호출한다 (크기 검증은 호출자 책임).
//  - 외부에서 토큰 텍스트를 커서 위치에 삽입하기 위해 CommandEditorController 를 노출한다.
//

import SwiftUI
import AppKit

/// 외부(부모 뷰)에서 명령어 편집기를 제어하기 위한 컨트롤러.
final class CommandEditorController: ObservableObject {
    fileprivate weak var textView: NSTextView?

    /// 현재 커서 위치(또는 선택 영역)에 텍스트 삽입.
    func insertAtCaret(_ s: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if tv.shouldChangeText(in: range, replacementString: s) {
            tv.textStorage?.replaceCharacters(in: range, with: s)
            tv.didChangeText()
            let newLoc = range.location + (s as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
        }
    }
}

/// 파일 드롭을 가로채는 NSTextView 서브클래스.
final class DropAwareTextView: NSTextView {
    var dropHandler: ((URL) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let types = pb.types, types.contains(.fileURL) else {
            return super.performDragOperation(sender)
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                dropHandler?(url)
            }
            return true
        }
        return super.performDragOperation(sender)
    }
}

struct DraggableCommandEditor: NSViewRepresentable {
    @Binding var text: String
    var onDropFile: (URL) -> Void
    let controller: CommandEditorController

    func makeNSView(context: Context) -> NSScrollView {
        // 스크롤 가능한 컨테이너 + DropAwareTextView 수동 구성
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]

        let contentSize = scroll.contentSize
        let tv = DropAwareTextView(frame: NSRect(origin: .zero, size: contentSize))
        tv.minSize = NSSize(width: 0, height: contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.delegate = context.coordinator
        tv.string = text
        tv.registerForDraggedTypes([.fileURL])

        let dropCb = onDropFile
        tv.dropHandler = { url in
            DispatchQueue.main.async {
                dropCb(url)
            }
        }

        scroll.documentView = tv
        context.coordinator.textView = tv
        controller.textView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        // 외부에서 text 가 바뀌면 동기화. 단, 동일하면 건드리지 않아 커서 위치를 유지.
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            // 커서 위치는 최대 길이로 클램프
            let maxLen = (text as NSString).length
            let clamped = NSRange(location: min(sel.location, maxLen), length: 0)
            tv.setSelectedRange(clamped)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.textBinding = text
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            textBinding.wrappedValue = tv.string
        }
    }
}
