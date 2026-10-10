import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { ApiClient } from '../api/ApiClient';
import { JsonMap, jsonGet, jsonStringValue } from '../api/JsonValue';

/**
 * 会话附件：选图 → 压缩 → 上传（对应 iOS `AgentComposer` 的图片链路 + `AgentImageCompressor`）。
 *
 * - 三种来源同一套处理：照片图库（`PhotoViewPicker`）、拍照（`cameraPicker`）、选取文件（`DocumentViewPicker`）；
 * - 压缩口径同 iOS/Web：**最长边 2048、JPEG 0.85**（视觉模型有效分辨率就在这个量级）；
 *   GIF 保持原样上传（压缩会丢动画帧），其余格式一律转 JPEG；
 * - 上传走**系统 http 的 multipart**（`multiFormDataList`）而不是 `request.uploadFile`：
 *   上传代理拿不到响应体，而这里要读回 `attachment_id`。
 */

/** 已上传、等待随消息发送的一张图 */
export class AgentAttachment {
  readonly attachmentId: string;
  readonly name: string;
  /** 本地预览地址（相册 / 文件 uri） */
  readonly uri: string;

  constructor(attachmentId: string, name: string, uri: string) {
    this.attachmentId = attachmentId;
    this.name = name;
    this.uri = uri;
  }
}

/** 压缩后的字节 + 元信息 */
export class AgentPreparedImage {
  readonly bytes: ArrayBuffer;
  readonly filename: string;
  readonly mimeType: string;

  constructor(bytes: ArrayBuffer, filename: string, mimeType: string) {
    this.bytes = bytes;
    this.filename = filename;
    this.mimeType = mimeType;
  }
}

export class AgentAttachments {
  /** 最长边（同 iOS `AgentImageCompressor.maxEdge`） */
  static readonly MAX_EDGE: number = 2048;
  /** 一条消息的图片上限（与服务端 `MAX_ATTACHMENTS_PER_MESSAGE` 一致） */
  static readonly MAX_PER_MESSAGE: number = 4;
  /** 「选取文件」可选的格式（同 Web `accept`） */
  static readonly PICK_SUFFIX: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];

  /** 照片图库（可多选） */
  static async pickFromLibrary(max: number): Promise<string[]> {
    const pickerInstance = new photoAccessHelper.PhotoViewPicker();
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = max;
    const picked: photoAccessHelper.PhotoSelectResult = await pickerInstance.select(options);
    return picked.photoUris;
  }

  /** 选取文件（沙盒外文件） */
  static async pickFiles(context: common.UIAbilityContext, max: number): Promise<string[]> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = max;
    options.fileSuffixFilters = AgentAttachments.PICK_SUFFIX;
    return await documentPicker.select(options);
  }

  /** 拍照 */
  static async capture(context: common.UIAbilityContext): Promise<string> {
    const result = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], {
      cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
    });
    return result.resultUri ?? '';
  }

  /** 读 → 压缩 → 上传，返回服务端给的附件编号 */
  static async prepareAndUpload(client: ApiClient, context: common.UIAbilityContext, uri: string,
    fallbackName: string): Promise<AgentAttachment> {
    const prepared: AgentPreparedImage = await AgentAttachments.prepare(uri, fallbackName);
    const url: string = `${client.origin}/api/v1/sessions/attachments`;
    const header: Record<string, string> = {
      'Accept': 'application/json',
      'Content-Type': 'multipart/form-data'
    };
    const token: string | null = client.getToken();
    if (token !== null && token.length > 0) {
      header['Authorization'] = `Bearer ${token}`;
    }
    const cookie: string = ApiClient.cookieHeaderFor(url);
    if (cookie.length > 0) {
      header['Cookie'] = cookie;
    }
    const form: http.MultiFormData[] = [{
      name: 'file',
      contentType: prepared.mimeType,
      remoteFileName: prepared.filename,
      data: prepared.bytes
    }];
    const response: http.HttpResponse = await http.createHttp().request(url, {
      method: http.RequestMethod.POST,
      header: header,
      multiFormDataList: form,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 30000,
      readTimeout: 60000
    });
    const body: string = typeof response.result === 'string' ? response.result : '';
    if (response.responseCode < 200 || response.responseCode >= 300) {
      throw new Error(body.length > 0 ? body : `上传失败（${response.responseCode}）`);
    }
    let payload: JsonMap | null = null;
    try {
      payload = JSON.parse(body) as JsonMap;
    } catch (error) {
      payload = null;
    }
    const attachmentId: string = payload === null
      ? '' : (jsonStringValue(jsonGet(payload, 'attachment_id')) ?? '');
    if (attachmentId.length === 0) {
      throw new Error('上传失败：服务端没有返回附件编号');
    }
    const name: string = jsonStringValue(jsonGet(payload, 'name')) ?? prepared.filename;
    return new AgentAttachment(attachmentId, name, uri);
  }

  /**
   * 压缩口径：GIF 原样（保留动画帧），其余最长边压到 2048 的 JPEG 0.85；
   * 没有原名时兜底「图片.jpg」（同 Web 的相机兜底）。
   */
  static async prepare(uri: string, fallbackName: string): Promise<AgentPreparedImage> {
    const lower: string = uri.toLowerCase();
    if (lower.endsWith('.gif')) {
      const raw: ArrayBuffer | null = AgentAttachments.readBytes(uri);
      if (raw !== null) {
        return new AgentPreparedImage(raw, AgentAttachments.fileName(uri, fallbackName, 'gif'), 'image/gif');
      }
    }
    const source: image.ImageSource = image.createImageSource(uri);
    try {
      const info: image.ImageInfo = await source.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      const longest: number = width >= height ? width : height;
      const scale: number = longest > AgentAttachments.MAX_EDGE
        ? AgentAttachments.MAX_EDGE / longest : 1;
      const target: image.Size = {
        width: Math.max(1, Math.round(width * scale)),
        height: Math.max(1, Math.round(height * scale))
      };
      const pixelMap: image.PixelMap = await source.createPixelMap({ desiredSize: target });
      const packer: image.ImagePacker = image.createImagePacker();
      const jpeg: ArrayBuffer = await packer.packing(pixelMap, { format: 'image/jpeg', quality: 85 });
      packer.release();
      pixelMap.release();
      return new AgentPreparedImage(jpeg, AgentAttachments.fileName(uri, fallbackName, 'jpg'),
        'image/jpeg');
    } finally {
      source.release();
    }
  }

  /** 去掉扩展名换成 `ext`；没有可用原名时用兜底名 */
  private static fileName(uri: string, fallbackName: string, ext: string): string {
    let base: string = fallbackName.trim();
    const slash: number = uri.lastIndexOf('/');
    const raw: string = slash >= 0 ? uri.substring(slash + 1) : uri;
    if (base.length === 0 && raw.length > 0 && raw.indexOf('.') > 0) {
      base = raw;
    }
    if (base.length === 0) {
      base = '图片';
    }
    const dot: number = base.lastIndexOf('.');
    if (dot > 0) {
      base = base.substring(0, dot);
    }
    return `${base}.${ext}`;
  }

  /** 直接读原始字节（失败返回 null，调用方退回压缩） */
  private static readBytes(uri: string): ArrayBuffer | null {
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const size: number = stat.size;
        if (size <= 0 || size > 20 * 1024 * 1024) {
          return null;
        }
        const buffer: ArrayBuffer = new ArrayBuffer(size);
        const read: number = fileIo.readSync(file.fd, buffer);
        return read > 0 ? buffer : null;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      return null;
    }
  }
}
