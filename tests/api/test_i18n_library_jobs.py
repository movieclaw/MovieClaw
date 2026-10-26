"""Library job messages keep a Chinese rollback value and render in the reader's language."""

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import localize_fields, stored_fields
from movieclaw_api.services.library import batch_transfer, transfer
from movieclaw_api.services.library.organize import render_organize_errors


def test_transfer_errors_render_per_reader():
    summary = transfer.TransferSummary(source_library_id=1, target_library_id=2, media_item_id=3)
    summary.add_error(transfer._MoveError("library.transfer.targetOccupied", path="/m/A").fields)
    summary.add_error(
        stored_fields(
            "library.transfer.sidecarFailed",
            detail=transfer._MoveError("library.transfer.sourceGone", path="/m/B").fields,
        )
    )
    assert summary.errors[0] == "目标路径已被占用，跳过以免覆盖：/m/A"
    with use_locale("en"):
        assert render_organize_errors(summary.errors, summary.error_messages) == [
            "Skipped to avoid overwriting: the target path is in use: /m/A",
            "Could not move an associated file: Skipped: the source is no longer in place: /m/B",
        ]


def test_transfer_completion_counts_skipped_issues():
    done = stored_fields("library.transfer.completed", title="Dune", library="4K", errors=0)
    issues = stored_fields("library.transfer.completed", title="Dune", library="4K", errors=2)
    assert done["message"] == "已把「Dune」转移到「4K」"
    assert issues["message"] == "已把「Dune」转移到「4K」，2 个问题已跳过"
    with use_locale("en"):
        assert localize_fields(issues)["message"] == "Transferred “Dune” to “4K”; 2 issues skipped"


def test_batch_skip_reasons_join_in_reader_language():
    outcome = batch_transfer.BatchOutcome()
    member = batch_transfer.BatchMember(media_item_id=7, title="Alien")
    batch_transfer._skip(
        outcome,
        member,
        [
            stored_fields("library.transfer.rootUnavailable", path="/x"),
            stored_fields("library.batchTransfer.nothingToMove"),
        ],
    )
    assert (
        outcome.skips[0]["reason"] == "目标库的主根路径不可访问：/x（盘未挂载？）；没有可搬运的内容"
    )
    with use_locale("en"):
        reason = localize_fields(outcome.skips)[0]["reason"]
    assert (
        reason
        == "The target library’s primary root is not accessible: /x (is the disk mounted?); "
        "Nothing to move"
    )


def test_batch_summary_message():
    outcome = batch_transfer.BatchOutcome(moved=3, skipped=1, failed=0)
    message = batch_transfer._summary_message(outcome, 4)
    assert message["message"] == "已转移 3 / 4 个条目，跳过 1 个"
    with use_locale("en"):
        assert localize_fields(message)["message"] == "Transferred 3 / 4 titles, 1 skipped"
