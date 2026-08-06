import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import UIKit

struct MetalPhotoUniform {
    var cameraInv = simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
    var intrinsics = simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
    var imageSize = SIMD2<Float>(1, 1)
    var closeUpWeight: Float = 1
    var pad = SIMD2<Float>(0, 0)
}

struct MetalBakeUniforms {
    var origin = SIMD4<Float>(0, 0, 0, 0)
    var uAxis = SIMD4<Float>(1, 0, 0, 0)
    var vAxis = SIMD4<Float>(0, 1, 0, 0)
    var normal = SIMD4<Float>(0, 0, 1, 0)
    var minU: Float = 0
    var minV: Float = 0
    var width: Float = 1
    var height: Float = 1
    var photoCount: Int32 = 0
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

final class MetalTextureBaker {
    static let shared = MetalTextureBaker()

    private let device: MTLDevice?
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?

    private init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            device = nil
            pipeline = nil
            sampler = nil
            return
        }
        device = metalDevice

        let library = try? metalDevice.makeLibrary(source: Self.shaderSource, options: nil)
        let vertexFunction = library?.makeFunction(name: "vertex_main")
        let fragmentFunction = library?.makeFunction(name: "fragment_main")
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        pipeline = try? metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = metalDevice.makeSamplerState(descriptor: samplerDescriptor)
    }

    var isAvailable: Bool {
        device != nil && pipeline != nil && sampler != nil
    }

    func bake(
        segment: TextureWallSegment,
        mesh: TextureScanMesh,
        photos: [TexturePhotoFrame],
        size: Int
    ) -> UIImage? {
        guard isAvailable, size > 0 else { return nil }
        let candidates = TextureBakeProcessor.selectPhotos(
            for: segment,
            mesh: mesh,
            photos: photos,
            maxCount: 2
        )
        guard !candidates.isEmpty else { return nil }

        var loadedTextures: [MTLTexture] = []
        var loadedPhotos: [TexturePhotoFrame] = []
        for photo in candidates {
            guard let texture = makeTexture(from: photo.fileURL) else { continue }
            loadedTextures.append(texture)
            loadedPhotos.append(photo)
            if loadedTextures.count >= 2 { break }
        }
        guard !loadedTextures.isEmpty else { return nil }

        guard let device, let pipeline, let sampler,
              let targetTexture = makeTargetTexture(size: size, device: device),
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPass = makeRenderPass(target: targetTexture),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return nil
        }

        var uniforms = MetalBakeUniforms()
        uniforms.origin = SIMD4<Float>(segment.origin.x, segment.origin.y, segment.origin.z, 0)
        uniforms.uAxis = SIMD4<Float>(segment.uAxis.x, segment.uAxis.y, segment.uAxis.z, 0)
        uniforms.vAxis = SIMD4<Float>(segment.vAxis.x, segment.vAxis.y, segment.vAxis.z, 0)
        uniforms.normal = SIMD4<Float>(segment.normal.x, segment.normal.y, segment.normal.z, 0)
        uniforms.minU = segment.minU
        uniforms.minV = segment.minV
        uniforms.width = segment.width
        uniforms.height = segment.height
        uniforms.photoCount = Int32(loadedPhotos.count)

        var photoUniforms: [MetalPhotoUniform] = []
        for photo in loadedPhotos {
            let inverse = simd_inverse(photo.cameraTransform)
            let fx = photo.intrinsics.columns.0.x
            let fy = photo.intrinsics.columns.1.y
            let cx = photo.intrinsics.columns.2.x
            let cy = photo.intrinsics.columns.2.y
            var intrinsics = simd_float4x4(columns: (
                SIMD4<Float>(fx, 0, 0, 0),
                SIMD4<Float>(0, fy, 0, 0),
                SIMD4<Float>(cx, cy, 1, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))
            _ = intrinsics
            var photoUniform = MetalPhotoUniform()
            photoUniform.cameraInv = inverse
            photoUniform.intrinsics = intrinsics
            photoUniform.imageSize = SIMD2<Float>(
                Float(photo.imageWidth),
                Float(photo.imageHeight)
            )
            photoUniform.closeUpWeight = photo.isCloseUp ? 2.5 : 1
            photoUniforms.append(photoUniform)
        }

        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        photoUniforms.withUnsafeBytes { raw in
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        for index in 0..<loadedTextures.count {
            encoder.setFragmentTexture(loadedTextures[index], index: index)
        }
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        targetTexture.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0
        )
        return makeImage(from: pixels, size: size, bytesPerRow: bytesPerRow)
    }

    private func makeTargetTexture(size: Int, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }

    private func makeRenderPass(target: MTLTexture) -> MTLRenderPassDescriptor? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.376,
            green: 0.408,
            blue: 0.463,
            alpha: 1
        )
        return descriptor
    }

    private func makeTexture(from url: URL) -> MTLTexture? {
        guard let device else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
              ) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    private func makeImage(from pixels: [UInt8], size: Int, bytesPerRow: Int) -> UIImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct PhotoUniform {
        float4x4 cameraInv;
        float4x4 intrinsics;
        float2 imageSize;
        float closeUpWeight;
        float2 pad;
    };

    struct Uniforms {
        float4 origin;
        float4 uAxis;
        float4 vAxis;
        float4 normal;
        float minU;
        float minV;
        float width;
        float height;
        int photoCount;
        float pad0;
        float pad1;
        float pad2;
    };

    vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
        float2 p;
        if (vertexID == 0) {
            p = float2(-1, -1);
        } else if (vertexID == 1) {
            p = float2(3, -1);
        } else {
            p = float2(-1, 3);
        }
        VertexOut out;
        out.position = float4(p, 0, 1);
        out.uv = p * 0.5 + 0.5;
        return out;
    }

    static float4 samplePhoto(
        int index,
        const device PhotoUniform* photos,
        array<texture2d<float>, 4> textures,
        sampler smp,
        float3 world,
        float3 normal
    ) {
        float4 cam = photos[index].cameraInv * float4(world, 1);
        if (cam.z <= 0.05) {
            return float4(0);
        }
        float4x4 k = photos[index].intrinsics;
        float2 pixel = float2(
            k[0][0] * cam.x / cam.z + k[2][0],
            k[1][1] * cam.y / cam.z + k[2][1]
        );
        if (pixel.x < 0 || pixel.y < 0 ||
            pixel.x >= photos[index].imageSize.x - 1 ||
            pixel.y >= photos[index].imageSize.y - 1) {
            return float4(0);
        }
        float2 uv = float2(
            pixel.x / photos[index].imageSize.x,
            pixel.y / photos[index].imageSize.y
        );
        float3 toCamera = normalize(-cam.xyz);
        float cosAngle = dot(normal, toCamera);
        if (cosAngle <= 0.25) {
            return float4(0);
        }
        float distance = length(cam.xyz);
        if (distance < 0.05 || distance > 5.0) {
            return float4(0);
        }
        float weight = cosAngle * cosAngle / (1.0 + distance * distance);
        weight *= photos[index].closeUpWeight;
        float4 color = textures[index].sample(smp, uv);
        return float4(color.rgb * weight, weight);
    }

    fragment float4 fragment_main(
        VertexOut in [[stage_in]],
        constant Uniforms& u [[buffer(0)]],
        const device PhotoUniform* photos [[buffer(1)]],
        texture2d<float> tex0 [[texture(0)]],
        texture2d<float> tex1 [[texture(1)]],
        texture2d<float> tex2 [[texture(2)]],
        texture2d<float> tex3 [[texture(3)]],
        sampler smp [[sampler(0)]]
    ) {
        float3 world = u.origin.xyz +
            u.uAxis.xyz * (u.minU + in.uv.x * u.width) +
            u.vAxis.xyz * (u.minV + in.uv.y * u.height);
        array<texture2d<float>, 4> textures = { tex0, tex1, tex2, tex3 };
        float3 sum = float3(0);
        float total = 0;
        int count = min(max(u.photoCount, 0), 4);
        for (int i = 0; i < count; i++) {
            float4 sample = samplePhoto(i, photos, textures, smp, world, u.normal.xyz);
            sum += sample.rgb;
            total += sample.a;
        }
        if (total > 0) {
            return float4(sum / total, 1);
        }
        return float4(0.376, 0.408, 0.463, 1);
    }
    """
}
