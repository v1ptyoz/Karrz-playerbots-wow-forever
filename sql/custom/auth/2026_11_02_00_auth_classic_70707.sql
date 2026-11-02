-- WoW Forever client 1.60.1.70707 (Battle.net update after 70658; the macOS client is on it).
-- advocaite's forever branch went 70450 -> 70532 -> 70630 -> 70634 -> 70658 with the same game data and protocol each time
-- (only client-side realm/region config, name filters and art changed), so these builds only need their build_info rows.
-- 70707 is assumed to be the same kind of update: its protocol is NOT verified yet.
-- No auth key is known for these builds: keep Network.SkipBuildAuthKeyCheck = 1 in worldserver.conf (macos/install.sh does).
-- bnetserver and worldserver read build_info only at startup: restart both after this update. Safe to run again.
DELETE FROM `build_info` WHERE `build` IN (70532,70630,70634,70658,70707);
INSERT INTO `build_info` (`build`,`majorVersion`,`minorVersion`,`bugfixVersion`,`hotfixVersion`) VALUES
(70532,1,60,1,NULL),
(70630,1,60,1,NULL),
(70634,1,60,1,NULL),
(70658,1,60,1,NULL),
(70707,1,60,1,NULL);

-- A realm lists for and accepts only clients of its exact gamebuild: the Forever realms 70-73 move to 70707.
-- To go back (for an older client), set their gamebuild to that build again; bnetserver re-reads the realm list by itself.
UPDATE `realmlist` SET `gamebuild`=70707 WHERE `id` IN (70,71,72,73) AND `gamebuild` IN (70450,70532,70630,70634,70658);
