"""Independent smart subscription policy, deadline and season follow state."""

import sqlalchemy as sa
from alembic import op

revision = "e7f4a1c9b203"
down_revision = "a5c3f19d7e42"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "smart_decision_record",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column(
            "wanted_id",
            sa.Integer(),
            sa.ForeignKey("wanted_item.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("mode", sa.String(), nullable=False),
        sa.Column("inputs", sa.JSON(), nullable=False),
        sa.Column("outcome", sa.JSON(), nullable=False),
    )
    op.create_index("ix_smart_decision_record_wanted_id", "smart_decision_record", ["wanted_id"])
    with op.batch_alter_table("subscription_download_attempt") as batch:
        batch.add_column(sa.Column("submission", sa.JSON(none_as_null=True), nullable=True))
    # SQLite validates referencing triggers while a table is rebuilt.
    op.execute("DROP TRIGGER IF EXISTS trg_subscription_activity_last_activity")
    with op.batch_alter_table("subscription") as batch:
        batch.add_column(
            sa.Column("selection_mode", sa.String(), nullable=False, server_default="rules")
        )
        batch.add_column(sa.Column("smart_policy", sa.JSON(none_as_null=True), nullable=True))
        batch.alter_column("rule_set_id", existing_type=sa.Integer(), nullable=True)
        batch.create_index("ix_subscription_selection_mode", ["selection_mode"])
        batch.create_check_constraint(
            "ck_subscription_selection_mode",
            "(selection_mode = 'rules' AND rule_set_id IS NOT NULL AND smart_policy IS "
            "NULL) OR (selection_mode = 'smart' AND rule_set_id IS NULL AND smart_policy "
            "IS NOT NULL)",
        )
    op.execute("""CREATE TRIGGER trg_subscription_activity_last_activity
        AFTER INSERT ON subscription_activity FOR EACH ROW BEGIN
        UPDATE subscription SET last_activity_at = MAX(last_activity_at, NEW.created_at)
        WHERE id = NEW.subscription_id; END""")
    with op.batch_alter_table("wanted_item") as batch:
        batch.add_column(sa.Column("selection_state", sa.JSON(none_as_null=True), nullable=True))
        batch.add_column(
            sa.Column("selection_version", sa.Integer(), nullable=False, server_default="0")
        )
        batch.add_column(sa.Column("next_selection_at", sa.DateTime(), nullable=True))
        batch.create_index("ix_wanted_item_next_selection_at", ["next_selection_at"])
        batch.create_index("ix_wanted_smart_due", ["status", "in_scope", "next_selection_at"])
    op.create_table(
        "smart_profile",
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("kind", sa.String(), primary_key=True),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("preferences", sa.JSON(), nullable=False),
    )
    op.create_table(
        "smart_season",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column(
            "subscription_id",
            sa.Integer(),
            sa.ForeignKey("subscription.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("season_number", sa.Integer(), nullable=False),
        sa.Column("series_key", sa.String(), nullable=False),
        sa.Column("confirmed", sa.Boolean(), nullable=False),
        sa.Column("evidence", sa.JSON(), nullable=False),
        sa.UniqueConstraint("subscription_id", "season_number", name="uq_smart_season"),
    )
    op.create_index("ix_smart_season_subscription_id", "smart_season", ["subscription_id"])
    op.create_table(
        "smart_candidate",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column(
            "subscription_id",
            sa.Integer(),
            sa.ForeignKey("subscription.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("site_id", sa.String(), nullable=False),
        sa.Column("torrent_id", sa.String(), nullable=False),
        sa.Column("snapshot", sa.JSON(), nullable=False),
        sa.Column("observations", sa.JSON(), nullable=False),
        sa.UniqueConstraint("subscription_id", "site_id", "torrent_id", name="uq_smart_candidate"),
    )
    op.create_index("ix_smart_candidate_subscription_id", "smart_candidate", ["subscription_id"])


def downgrade() -> None:
    connection = op.get_bind()
    has_smart = connection.execute(sa.text(
        "SELECT EXISTS(SELECT 1 FROM subscription WHERE selection_mode='smart') "
        "OR EXISTS(SELECT 1 FROM smart_profile)"
    )).scalar()
    if has_smart:
        raise RuntimeError("存在智能订阅或设置，禁止直接回退；请恢复升级前的完整备份")
    # 尚未启用智能模式的数据库可无损回退，保留所有规则订阅。
    for table in ("smart_decision_record", "smart_candidate", "smart_season", "smart_profile"):
        op.drop_table(table)
    with op.batch_alter_table("wanted_item") as batch:
        batch.drop_index("ix_wanted_smart_due")
        batch.drop_index("ix_wanted_item_next_selection_at")
        batch.drop_column("selection_state")
        batch.drop_column("selection_version")
        batch.drop_column("next_selection_at")
    with op.batch_alter_table("subscription_download_attempt") as batch:
        batch.drop_column("submission")
    op.execute("DROP TRIGGER IF EXISTS trg_subscription_activity_last_activity")
    with op.batch_alter_table("subscription") as batch:
        batch.drop_constraint("ck_subscription_selection_mode", type_="check")
        batch.drop_index("ix_subscription_selection_mode")
        batch.drop_column("selection_mode")
        batch.drop_column("smart_policy")
        batch.alter_column("rule_set_id", existing_type=sa.Integer(), nullable=False)
    op.execute("""CREATE TRIGGER trg_subscription_activity_last_activity
        AFTER INSERT ON subscription_activity FOR EACH ROW BEGIN
        UPDATE subscription SET last_activity_at = MAX(last_activity_at, NEW.created_at)
        WHERE id = NEW.subscription_id; END""")
