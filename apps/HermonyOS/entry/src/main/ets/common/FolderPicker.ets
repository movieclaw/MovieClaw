import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/**
 * 选一个文件夹，返回 **URI**（`file://docs/...` 这种）。
 *
 * 对应 iOS 新建库向导里选根目录的那一步（iOS 用 `.fileImporter` 的目录模式）。
 * 鸿蒙这边用系统自带的 `DocumentViewPicker` 的文件夹模式——
 * 这是系统组件，不是自绘，用户熟悉、权限也由系统弹窗处理。
 *
 * 后端要的是**服务器上能看到的路径**，而选择器给的是本机 URI；
 * 两者的对应关系由后端在扫描时解析（它认识 `file://docs/...` 这类根）。
 * 真机上选的是本机目录，能不能用取决于服务端与设备是否同一台——
 * 所以调用方要允许用户手输路径（见 `LibraryCreatePage` 的「手动输入」）。
 */
export async function pickFolder(): Promise<string> {
  const context = getContext() as common.UIAbilityContext;
  const documentPicker = new picker.DocumentViewPicker(context);
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  options.selectMode = picker.DocumentSelectMode.FOLDER;
  const uris: string[] = await documentPicker.select(options);
  return uris.length > 0 ? uris[0] : '';
}
