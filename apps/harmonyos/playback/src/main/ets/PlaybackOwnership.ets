/** In-app audio ownership shared with preview players. Claiming pauses the previous owner. */
export class PlaybackOwnership {
  private static owner: Object | null = null;
  private static revoke: (() => void) | null = null;
  static claim(owner: Object, revoke: () => void): void {
    if (PlaybackOwnership.owner !== owner) {
      const previous = PlaybackOwnership.revoke;
      PlaybackOwnership.owner = owner; PlaybackOwnership.revoke = revoke;
      previous?.();
    }
  }
  static release(owner: Object): void {
    if (PlaybackOwnership.owner === owner) {
      PlaybackOwnership.owner = null; PlaybackOwnership.revoke = null;
    }
  }
}
