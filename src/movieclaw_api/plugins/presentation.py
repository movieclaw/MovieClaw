"""Reader-specific labels for application-owned plugin metadata; kernel objects stay neutral."""

from typing import Literal

from movieclaw_api.i18n import t

BUILTIN_MESSAGE_KEYS: dict[str, dict[str, str]] = {
    "core.demo-seed": {
        "title": "plugins.builtins.coreDemoSeedTitle",
        "description": "plugins.builtins.coreDemoSeedDescription",
    },
    "core.demo-site": {
        "title": "plugins.builtins.coreDemoSiteTitle",
        "description": "plugins.builtins.coreDemoSiteDescription",
    },
    "core.database": {
        "title": "plugins.builtins.coreDatabaseTitle",
        "description": "plugins.builtins.coreDatabaseDescription",
    },
    "core.registries": {
        "title": "plugins.builtins.coreRegistriesTitle",
        "description": "plugins.builtins.coreRegistriesDescription",
    },
    "kernel.durable-events": {
        "title": "plugins.builtins.kernelDurableEventsTitle",
        "description": "plugins.builtins.kernelDurableEventsDescription",
    },
    "kernel.plugin-events": {
        "title": "plugins.builtins.kernelPluginEventsTitle",
        "description": "plugins.builtins.kernelPluginEventsDescription",
    },
    "kernel.host-ops": {
        "title": "plugins.builtins.kernelHostOpsTitle",
        "description": "plugins.builtins.kernelHostOpsDescription",
    },
    "kernel.plugin-data": {
        "title": "plugins.builtins.kernelPluginDataTitle",
        "description": "plugins.builtins.kernelPluginDataDescription",
    },
    "kernel.plugin-jobs": {
        "title": "plugins.builtins.kernelPluginJobsTitle",
        "description": "plugins.builtins.kernelPluginJobsDescription",
    },
    "kernel.plugin-health": {
        "title": "plugins.builtins.kernelPluginHealthTitle",
        "description": "plugins.builtins.kernelPluginHealthDescription",
    },
    "kernel.plugin-routes": {
        "title": "plugins.builtins.kernelPluginRoutesTitle",
        "description": "plugins.builtins.kernelPluginRoutesDescription",
    },
    "kernel.plugin-callbacks": {
        "title": "plugins.builtins.kernelPluginCallbacksTitle",
        "description": "plugins.builtins.kernelPluginCallbacksDescription",
    },
    "kernel.plugin-files": {
        "title": "plugins.builtins.kernelPluginFilesTitle",
        "description": "plugins.builtins.kernelPluginFilesDescription",
    },
    "core.secrets": {
        "title": "plugins.builtins.coreSecretsTitle",
        "description": "plugins.builtins.coreSecretsDescription",
    },
    "core.settings": {
        "title": "plugins.builtins.coreSettingsTitle",
        "description": "plugins.builtins.coreSettingsDescription",
    },
    "kernel.notices": {
        "title": "plugins.builtins.kernelNoticesTitle",
        "description": "plugins.builtins.kernelNoticesDescription",
    },
    "core.egress": {
        "title": "plugins.builtins.coreEgressTitle",
        "description": "plugins.builtins.coreEgressDescription",
    },
    "core.scrape-runtime": {
        "title": "plugins.builtins.coreScrapeRuntimeTitle",
        "description": "plugins.builtins.coreScrapeRuntimeDescription",
    },
    "playback.remote-config": {
        "title": "plugins.builtins.playbackRemoteConfigTitle",
        "description": "plugins.builtins.playbackRemoteConfigDescription",
    },
    "core.http-clients": {
        "title": "plugins.builtins.coreHttpClientsTitle",
        "description": "plugins.builtins.coreHttpClientsDescription",
    },
    "tracker.sites": {
        "title": "plugins.builtins.trackerSitesTitle",
        "description": "plugins.builtins.trackerSitesDescription",
    },
    "tracker.site-access": {
        "title": "plugins.builtins.trackerSiteAccessTitle",
        "description": "plugins.builtins.trackerSiteAccessDescription",
    },
    "selfheal.credentials": {
        "title": "plugins.builtins.selfhealCredentialsTitle",
        "description": "plugins.builtins.selfhealCredentialsDescription",
    },
    "library.builtin-collections": {
        "title": "plugins.builtins.libraryBuiltinCollectionsTitle",
        "description": "plugins.builtins.libraryBuiltinCollectionsDescription",
    },
    "agent.runs": {
        "title": "plugins.builtins.agentRunsTitle",
        "description": "plugins.builtins.agentRunsDescription",
    },
    "agent.session-index": {
        "title": "plugins.builtins.agentSessionIndexTitle",
        "description": "plugins.builtins.agentSessionIndexDescription",
    },
    "agent.attachments": {
        "title": "plugins.builtins.agentAttachmentsTitle",
        "description": "plugins.builtins.agentAttachmentsDescription",
    },
    "agent.invoke": {
        "title": "plugins.builtins.agentInvokeTitle",
        "description": "plugins.builtins.agentInvokeDescription",
    },
    "enrich.backfill": {
        "title": "plugins.builtins.enrichBackfillTitle",
        "description": "plugins.builtins.enrichBackfillDescription",
    },
    "library.disc-image-durations": {
        "title": "plugins.builtins.libraryDiscImageDurationsTitle",
        "description": "plugins.builtins.libraryDiscImageDurationsDescription",
    },
    "library.dolby-vision-backfill": {
        "title": "plugins.builtins.libraryDolbyVisionBackfillTitle",
        "description": "plugins.builtins.libraryDolbyVisionBackfillDescription",
    },
    "app-update": {
        "title": "plugins.builtins.appUpdateTitle",
        "description": "plugins.builtins.appUpdateDescription",
    },
    "app-update.startup-check": {
        "title": "plugins.builtins.appUpdateStartupCheckTitle",
        "description": "plugins.builtins.appUpdateStartupCheckDescription",
    },
    "downloads": {
        "title": "plugins.builtins.downloadsTitle",
        "description": "plugins.builtins.downloadsDescription",
    },
    "boost": {
        "title": "plugins.builtins.boostTitle",
        "description": "plugins.builtins.boostDescription",
    },
    "subscription": {
        "title": "plugins.builtins.subscriptionTitle",
        "description": "plugins.builtins.subscriptionDescription",
    },
    "tracker.search-runs": {
        "title": "plugins.builtins.trackerSearchRunsTitle",
        "description": "plugins.builtins.trackerSearchRunsDescription",
    },
    "library.core": {
        "title": "plugins.builtins.libraryCoreTitle",
        "description": "plugins.builtins.libraryCoreDescription",
    },
    "media.scrape": {
        "title": "plugins.builtins.mediaScrapeTitle",
        "description": "plugins.builtins.mediaScrapeDescription",
    },
    "subtitle.gen": {
        "title": "plugins.builtins.subtitleGenTitle",
        "description": "plugins.builtins.subtitleGenDescription",
    },
    "scheduler": {
        "title": "plugins.builtins.schedulerTitle",
        "description": "plugins.builtins.schedulerDescription",
    },
    "boost.sentinel": {
        "title": "plugins.builtins.boostSentinelTitle",
        "description": "plugins.builtins.boostSentinelDescription",
    },
    "library.watch": {
        "title": "plugins.builtins.libraryWatchTitle",
        "description": "plugins.builtins.libraryWatchDescription",
    },
    "library.ingest-watch": {
        "title": "plugins.builtins.libraryIngestWatchTitle",
        "description": "plugins.builtins.libraryIngestWatchDescription",
    },
    "channels.hub": {
        "title": "plugins.builtins.channelsHubTitle",
        "description": "plugins.builtins.channelsHubDescription",
    },
    "cloud": {
        "title": "plugins.builtins.cloudTitle",
        "description": "plugins.builtins.cloudDescription",
    },
    "push.hub": {
        "title": "plugins.builtins.pushHubTitle",
        "description": "plugins.builtins.pushHubDescription",
    },
    "webhook.delivery": {
        "title": "plugins.builtins.webhookDeliveryTitle",
        "description": "plugins.builtins.webhookDeliveryDescription",
    },
    "push.channels-refresh": {
        "title": "plugins.builtins.pushChannelsRefreshTitle",
        "description": "plugins.builtins.pushChannelsRefreshDescription",
    },
    "push.arrivals": {
        "title": "plugins.builtins.pushArrivalsTitle",
        "description": "plugins.builtins.pushArrivalsDescription",
    },
    "jellyfin.discovery": {
        "title": "plugins.builtins.jellyfinDiscoveryTitle",
        "description": "plugins.builtins.jellyfinDiscoveryDescription",
    },
    "jobs": {
        "title": "plugins.builtins.jobsTitle",
        "description": "plugins.builtins.jobsDescription",
    },
    "library.search-index": {
        "title": "plugins.builtins.librarySearchIndexTitle",
        "description": "plugins.builtins.librarySearchIndexDescription",
    },
    "library.media-server-refresh": {
        "title": "plugins.builtins.libraryMediaServerRefreshTitle",
        "description": "plugins.builtins.libraryMediaServerRefreshDescription",
    },
    "storage.guard": {
        "title": "plugins.builtins.storageGuardTitle",
        "description": "plugins.builtins.storageGuardDescription",
    },
    "subtitle.pgs-warm": {
        "title": "plugins.builtins.subtitlePgsWarmTitle",
        "description": "plugins.builtins.subtitlePgsWarmDescription",
    },
    "library.skip-segments": {
        "title": "plugins.builtins.librarySkipSegmentsTitle",
        "description": "plugins.builtins.librarySkipSegmentsDescription",
    },
    "playback.remote-workers": {
        "title": "plugins.builtins.playbackRemoteWorkersTitle",
        "description": "plugins.builtins.playbackRemoteWorkersDescription",
    },
    "drives.sources": {
        "title": "plugins.builtins.drivesSourcesTitle",
        "description": "plugins.builtins.drivesSourcesDescription",
    },
    "drives.uploads": {
        "title": "plugins.builtins.drivesUploadsTitle",
        "description": "plugins.builtins.drivesUploadsDescription",
    },
    "playback.transcode": {
        "title": "plugins.builtins.playbackTranscodeTitle",
        "description": "plugins.builtins.playbackTranscodeDescription",
    },
}


def builtin_text(entry_id: str, field: Literal["title", "description"], fallback: str) -> str:
    key = BUILTIN_MESSAGE_KEYS.get(entry_id, {}).get(field)
    return t(key) if key else fallback


GROUP_MESSAGE_KEYS = (
    "plugins.groups.core",
    "plugins.groups.sitesDownloads",
    "plugins.groups.subscriptions",
    "plugins.groups.libraries",
    "plugins.groups.playbackSubtitles",
    "plugins.groups.notificationsPush",
    "plugins.groups.assistant",
    "plugins.groups.pluginSystem",
)


def group_labels() -> dict[str, str]:
    from movieclaw_api.plugins.manifest import BUILTIN_GROUPS

    return {
        label: t(key) for (label, _), key in zip(BUILTIN_GROUPS, GROUP_MESSAGE_KEYS, strict=True)
    }
