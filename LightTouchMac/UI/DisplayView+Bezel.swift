import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    @objc func bezelPreferenceChanged() { applyBezel(freeFormActive ? .off : Self.bezel) }

    /// The device around the screen, its flat art, or the screen alone. Flat and bare drop the model (and its
    /// load); bare also empties the shell layer, which stays as the screen's transform: rotation, zoom and touch
    /// mapping are unchanged.
    func applyBezel(_ bezel: Bezel) {
        guard bezel != appliedBezel else { return }
        appliedBezel = bezel
        bare = bezel == .off
        modelLoadTask?.cancel()
        modelFallbackTask?.cancel()
        modelLoadTask = nil
        for model in [modelView, pendingModelView] { model?.removeFromSuperview() }
        modelView = nil
        pendingModelView = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.removeAnimation(forKey: "modelPresentation")
        shellLayer.contents =
            bare ? nil : NSImage(named: profile.shellImageName)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        shellLayer.shadowOpacity = bare ? 0 : 0.4
        // Bare, the transform turns and scales about the screen's center, which layout() puts at the pane's.
        shellLayer.anchorPoint =
            bare
            ? CGPoint(x: screenCutout.midX / shellPixels.width, y: screenCutout.midY / shellPixels.height)
            : CGPoint(x: 0.5, y: 0.5)
        shellLayer.isHidden = false
        CATransaction.commit()
        modelPresentationFinished = true
        // macOS 14 keeps the photo shell; RealityKit texture rotation requires 15.
        if bezel == .model, #available(macOS 15, *), let name = profile.deviceModelName,
            let url = Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: "Models")
        {
            modelPresentationFinished = false
            // Give RealityKit one second to present the device itself. Slower
            // startup shows a temporary photo while the live model keeps
            // loading; a busy GPU must never permanently disable 3D.
            shellLayer.isHidden = true
            homeButton.isHidden = true
            let profile = profile
            modelFallbackTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.showStaticDevice()
            }
            modelLoadTask = Task { [weak self] in
                do {
                    let model = try await DeviceModelView(url: url, profile: profile)
                    try Task.checkCancellation()
                    guard self?.stageModelForPresentation(model) == true else { return }
                    let frameReady = await model.prepareFirstFrame()
                    try Task.checkCancellation()
                    // Do not retain the display across a renderer callback. A
                    // stalled snapshot must not keep a closed window alive.
                    guard frameReady else { return }
                    self?.presentModel(model)
                } catch is CancellationError {} catch {
                    NSLog("%@ model could not load: %@", name, error.localizedDescription)
                    self?.showStaticDevice()
                }
            }
        }
        needsLayout = true
    }

    private func stageModelForPresentation(_ model: DeviceModelView) -> Bool {
        guard modelView == nil else { return false }
        addSubview(model, positioned: .below, relativeTo: homeButton)
        pendingModelView = model
        model.alphaValue = 0
        model.setScreenOff(powerPresentation != .awake)
        if let image = captureFrame(includeTouches: false) { model.updateFrame(image) }
        needsLayout = true
        layoutSubtreeIfNeeded()
        return true
    }

    private func showStaticDevice() {
        guard modelView == nil else { return }
        modelPresentationFinished = true
        modelFallbackTask?.cancel()
        shellLayer.isHidden = false
        needsLayout = true
    }

    private func presentModel(_ model: DeviceModelView) {
        guard modelView == nil else { return }
        modelPresentationFinished = true
        modelFallbackTask?.cancel()
        pendingModelView = nil
        modelView = model
        model.setScreenOff(powerPresentation != .awake)
        needsLayout = true
        layoutSubtreeIfNeeded()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.2
        if !shellLayer.isHidden, duration > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shellLayer.opacity
            fade.toValue = 0
            fade.duration = duration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            shellLayer.add(fade, forKey: "modelPresentation")
        } else {
            shellLayer.isHidden = true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            model.animator().alphaValue = CGFloat(shellLayer.opacity)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.shellLayer.isHidden = true
                self?.shellLayer.removeAnimation(forKey: "modelPresentation")
            }
        }
    }
}
