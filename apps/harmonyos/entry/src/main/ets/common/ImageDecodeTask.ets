import { image } from '@kit.ImageKit';

/**
 * 图片子线程解码任务：原始编码字节 + 解码单边上限 → PixelMap。
 *
 * 单独成文件：@Concurrent 并发函数不能是闭包、不能与组件/状态代码混住，
 * 入参返回值都必须是可跨线程传输的类型（ArrayBuffer / PixelMap 均支持）。
 * 解码（尤其 4K 原片降采样）是 CPU 大户，挪出主线程后海报墙滚动不再被解码卡顿。
 *
 * 尺寸语义与原实现一致：按原图比例缩到单边不超 capEdge，不变形；
 * 本来就不超限时按原尺寸解。capEdge <= 0 视为不设限。
 */
@Concurrent
export async function decodeImageBytes(buffer: ArrayBuffer, capEdge: number): Promise<image.PixelMap | null> {
  try {
    const source: image.ImageSource = image.createImageSource(buffer);
    try {
      const info: image.ImageInfo = source.getImageInfoSync();
      const width: number = info.size.width;
      const height: number = info.size.height;
      const longest: number = Math.max(width, height);
      if (width > 0 && height > 0 && capEdge > 0 && longest > capEdge) {
        const ratio: number = capEdge / longest;
        const target: image.Size = {
          width: Math.round(width * ratio),
          height: Math.round(height * ratio)
        };
        return await source.createPixelMap({ desiredSize: target });
      }
      return await source.createPixelMap();
    } finally {
      await source.release();
    }
  } catch (error) {
    return null;
  }
}
