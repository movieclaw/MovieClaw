import { describe, it, expect } from '@ohos/hypium';
import { AccountView } from '../main/ets/api/Models';
import { ServerAddress } from '../main/ets/common/ServerAddress';
import { SavedServer, SavedServers } from '../main/ets/common/SavedServers';

/**
 * SavedServers 纯函数的单测（对应 iOS 端 `SavedServersTests`）。
 *
 * 这里**只测不碰存储的那几个函数**——它们是「多账号」的核心逻辑，
 * 出错了表现很隐蔽（账号列表顺序乱、当前账号标错、切号后旧账号没被取消「当前」）。
 */
function acc(username: string, active: boolean): AccountView {
  return { username: username, nickname: username, avatar_url: null, role: 'member', active: active };
}

export default function savedServersTest() {
  describe('SavedServers', () => {
    const serverA: ServerAddress = ServerAddress.trusted('http://a.test:13000');
    const serverB: ServerAddress = ServerAddress.trusted('http://b.test:13000');

    it('touching_新增服务器并置顶最近使用的', 0, () => {
      let list: SavedServer[] = [];
      list = SavedServers.touching(list, serverA, [acc('ann', true)], 100);
      list = SavedServers.touching(list, serverB, [acc('bob', true)], 200);
      expect(list.length).assertEqual(2);
      expect(list[0].address.origin).assertEqual(serverB.origin);

      list = SavedServers.touching(list, serverA, null, 300);
      expect(list[0].address.origin).assertEqual(serverA.origin);
      // 只更新时间时不能把账号快照冲掉
      expect(list[0].accounts.length).assertEqual(1);
    });

    it('upserting_新账号置顶且旧账号取消当前', 0, () => {
      let list: SavedServer[] = [];
      list = SavedServers.touching(list, serverA, [acc('ann', true)], 100);
      list = SavedServers.upserting(list, serverA, acc('ann2', true), 100);
      const saved: SavedServer | null = SavedServers.find(list, serverA);
      expect(saved === null).assertFalse();
      const accounts: AccountView[] = (saved as SavedServer).accounts;
      expect(accounts.length).assertEqual(2);
      expect(accounts[0].username).assertEqual('ann2');
      expect(accounts[0].active).assertTrue();
      // 同一台服务器只能有一个「当前」账号
      expect(accounts[1].active).assertFalse();
    });

    it('upserting_同名账号是替换而不是追加', 0, () => {
      let list: SavedServer[] = [];
      list = SavedServers.touching(list, serverA, [acc('ann', true)], 100);
      list = SavedServers.upserting(list, serverA, acc('ann', false), 100);
      const saved: SavedServer | null = SavedServers.find(list, serverA);
      expect((saved as SavedServer).accounts.length).assertEqual(1);
      expect((saved as SavedServer).accounts[0].active).assertFalse();
    });

    it('upserting_用户名不区分大小写地替换', 0, () => {
      let list: SavedServer[] = [];
      list = SavedServers.touching(list, serverA, [acc('Ann', true)], 100);
      list = SavedServers.upserting(list, serverA, acc('ann', true), 100);
      expect((SavedServers.find(list, serverA) as SavedServer).accounts.length).assertEqual(1);
    });

    it('upserting_服务器还没记录时先建一台', 0, () => {
      let list: SavedServer[] = [];
      list = SavedServers.upserting(list, serverA, acc('ann', true), 100);
      expect(list.length).assertEqual(1);
      expect(list[0].address.origin).assertEqual(serverA.origin);
    });

    it('replacingAccounts_只换账号快照不动排序', 0, () => {
      let list: SavedServer[] = [];
      list = SavedServers.touching(list, serverA, [acc('ann', true)], 100);
      list = SavedServers.touching(list, serverB, [acc('bob', true)], 200);
      list = SavedServers.replacingAccounts(list, serverB, [acc('b1', true), acc('b2', false)]);
      expect(list[0].address.origin).assertEqual(serverB.origin);
      expect((SavedServers.find(list, serverB) as SavedServer).accounts.length).assertEqual(2);
      // A 不受影响
      expect((SavedServers.find(list, serverA) as SavedServer).accounts.length).assertEqual(1);
    });

    it('removingAccount_只删指定服务器上的那个账号', 0, () => {
      let list: SavedServer[] = [];
      list = SavedServers.touching(list, serverA, [acc('ann', true), acc('ann2', false)], 100);
      list = SavedServers.touching(list, serverB, [acc('ann', true)], 200);
      list = SavedServers.removingAccount(list, 'ann', serverA);
      const a: SavedServer = SavedServers.find(list, serverA) as SavedServer;
      expect(a.accounts.length).assertEqual(1);
      expect(a.accounts[0].username).assertEqual('ann2');
      // 另一台服务器上的同名账号不该被牵连
      expect((SavedServers.find(list, serverB) as SavedServer).accounts.length).assertEqual(1);
    });

    it('activeAccount_优先取标记为当前的', 0, () => {
      const saved: SavedServer = new SavedServer(serverA, [acc('a', false), acc('b', true)], 100);
      expect((saved.activeAccount() as AccountView).username).assertEqual('b');
      // 都没标记时退回第一个（对应 iOS `?? accounts.first`）
      const none: SavedServer = new SavedServer(serverA, [acc('a', false), acc('b', false)], 100);
      expect((none.activeAccount() as AccountView).username).assertEqual('a');
    });

    it('holds_按用户名判断这台服务器上有没有该账号', 0, () => {
      const saved: SavedServer = new SavedServer(serverA, [acc('Ann', true)], 100);
      expect(saved.holds('ann')).assertTrue();
      expect(saved.holds('nobody')).assertFalse();
    });

    it('snapshot_把会话字段搬成账号快照', 0, () => {
      const view: AccountView = SavedServers.snapshot('u', '昵称', 'http://img/x.png', 'admin', true);
      expect(view.username).assertEqual('u');
      expect(view.nickname).assertEqual('昵称');
      expect(view.avatar_url).assertEqual('http://img/x.png');
      expect(view.role).assertEqual('admin');
      expect(view.active).assertTrue();
    });
  });
}
