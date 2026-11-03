-- Classic 1.60.1.70707: SpellDuration.db2 has DurationPerLevel again (layout 0x4FDF0951), between Duration and MaxDuration.
ALTER TABLE `spell_duration` ADD COLUMN `DurationPerLevel` int NOT NULL DEFAULT '0' AFTER `Duration`;
