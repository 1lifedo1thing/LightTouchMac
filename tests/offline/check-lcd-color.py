#!/usr/bin/env python3
"""The live LCD's colors on a wide-gamut display: the helper's frame surface (Shared/SharedStatus.makeSurface) holding
pure red (255, 0, 0), composited by Core Animation into a Display P3 target as a P3 screen would, must come out as
sRGB red in P3 (about 234, 51, 35), not P3's own red (255, 0, 0, oversaturated)."""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'scripts'))
import device_runtime
code = r'''import Cocoa
import Metal
@main struct Check { static func main() {
 let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
 let surface = makeSurface(width: 8, height: 8)
 surface.lock(options: [], seed: nil)
 let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
 for y in 0..<8 { for x in 0..<8 { let o = y * surface.bytesPerRow + x * 4; p[o] = 0; p[o+1] = 0; p[o+2] = 255; p[o+3] = 255 } }
 surface.unlock(options: [], seed: nil)
 let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
 desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .managed
 let texture = device.makeTexture(descriptor: desc)!
 CATransaction.begin(); CATransaction.setDisableActions(true)
 let layer = CALayer(); layer.frame = CGRect(x: 0, y: 0, width: 8, height: 8); layer.contents = surface
 let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                        kCARendererMetalCommandQueue: queue])
 renderer.layer = layer; renderer.bounds = layer.frame
 CATransaction.commit(); CATransaction.flush()
 renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil); renderer.addUpdate(renderer.bounds); renderer.render(); renderer.endFrame()
 let b = queue.makeCommandBuffer()!, blit = b.makeBlitCommandEncoder()!
 blit.synchronize(resource: texture); blit.endEncoding(); b.commit(); b.waitUntilCompleted()
 var px = [UInt8](repeating: 0, count: 256)
 texture.getBytes(&px, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
 let (b0, g0, r0) = (Int(px[144]), Int(px[145]), Int(px[146]))
 precondition(abs(r0 - 234) <= 3 && abs(g0 - 51) <= 4 && abs(b0 - 35) <= 4, "pure red on a P3 screen: (\(r0), \(g0), \(b0)); (255, 0, 0) is oversaturated")
 print("PASS: the live LCD's pure red shows as sRGB red on a P3 screen (\(r0), \(g0), \(b0))")
}}
'''
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp); (tmp / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', *device_runtime.swift_flags(root), '-parse-as-library', str(root / 'Packages/DeviceRuntime/Sources/DeviceRuntime/SharedStatus.swift'), str(tmp / 'check.swift'),
                    '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True, timeout=60)
