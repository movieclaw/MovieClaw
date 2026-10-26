/**
 * 会话页的路由参数。
 *
 * 独立小文件：ChatPage.ets 体积很大，入口页只需要参数类就能压路由，
 * 不应为了它把整个会话页拉进启动模块图。
 */

/** 会话页的路由参数（会序列化，不要用 instanceof） */
export class ChatParams {
  readonly sessionId: string;

  constructor(sessionId: string) {
    this.sessionId = sessionId;
  }

  static of(param: Object | undefined | null): ChatParams | null {
    if (param === undefined || param === null) {
      // 没带参数也是「新会话」
      return new ChatParams('');
    }
    const raw: ChatParams = param as ChatParams;
    const id: string = raw.sessionId;
    // 空 id 合法：表示**新会话**（同 iOS `.newSession`）——会话在第一条消息时才由服务端建出来
    if (id === undefined || id === null) {
      return new ChatParams('');
    }
    return new ChatParams(id);
  }
}
