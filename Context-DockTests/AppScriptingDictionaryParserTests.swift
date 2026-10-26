// AppScriptingDictionaryParserTests.swift
// Context-DockTests
//
// The dictionary rung's parser against recorded `sdef` output of three apps (P13 #208
// done-when): Mail and Music (system apps, excerpts of their real sdef XML) and Spotify
// (a third-party app, its full recorded file). The learner never runs `sdef` here — it
// parses text — so the suite runs with no live app and no Apple Event, offline.

import Testing
@testable import Context_Dock

@Suite
struct AppScriptingDictionaryParserTests {

    // MARK: Fixtures — recorded sdef output

    /// Recorded from `/usr/bin/sdef /System/Applications/Mail.app` (excerpt): the
    /// Standard Suite's generic commands, Mail's hidden duplicates, the class-extension
    /// that hangs elements on the Standard application, and the message class with a
    /// nested-type property and a hidden write-only property.
    static let mailExcerpt = """
        <?xml version="1.0" encoding="UTF-8"?>
        <dictionary title="Mail">
        <suite name="Standard Suite" code="????" description="Common terms for most commands.">
        <command name="open" code="aevtodoc"><direct-parameter><type name="document"/></direct-parameter></command>
        <command name="close" code="coreclos" description="Close an object."><direct-parameter><type name="specifier"/></direct-parameter><parameter name="saving" code="savo" type="SaveOptions" optional="yes"/></command>
        <command name="delete" code="coredelo" description="Delete an object."><direct-parameter><type name="specifier"/></direct-parameter></command>
        <command name="duplicate" code="coreclon" description="Copy an object."><direct-parameter><type name="specifier"/></direct-parameter><parameter name="with properties" code="prdt" type="record" optional="yes"/></command>
        <command name="move" code="coremove" description="Move an object to a new location."><direct-parameter><type name="specifier"/></direct-parameter><parameter name="to" code="to  " type="location specifier"/></command>
        <event name="open location" code="aevtGURL"><direct-parameter type="text"/></event>
        <class name="application" code="capp" description="The application's top level scripting object."><property name="name" code="pnam" type="text" access="r"/><property name="version" code="vers" type="text" access="r"/></class>
        </suite>
        <suite name="Mail Framework" code="emsg" description="Classes and commands for the Mail framework.">
        <command name="bounce" code="emalbcms" hidden="yes" description="Does nothing at all (deprecated)"/>
        <command name="check for new mail" code="emalchma" description="Triggers a check for email."/>
        <command name="delete" code="coredelo" hidden="yes" description="Delete an object."/>
        <command name="extract name from" code="emaleafn" description="Command to get the full name out of a fully specified email address."><direct-parameter type="text"/></command>
        <command name="forward" code="emalfwms" description="Creates a forwarded message."><direct-parameter type="message"/><parameter name="to" code="to  " type="text" optional="yes"/></command>
        <command name="reply" code="emalrpms" description="Creates a reply message."><direct-parameter type="message"/><parameter name="reply to all" code="rpal" type="boolean" optional="yes"/></command>
        <command name="send" code="emsgsend" description="Sends a message."><direct-parameter type="outgoing message"/><result type="boolean"/></command>
        <command name="synchronize" code="emalsyac" description="Command to trigger synchronizing of an IMAP account with the server."><parameter name="with" code="acna" type="account" description="The account to synchronize"/></command>
        <class name="message" code="mssg" description="An email message">
        <element type="header"/>
        <property name="id" code="ID  " type="integer" access="r" description="The unique identifier of the message."/>
        <property name="subject" code="subj" type="text" access="r" description="The subject of the message"/>
        <property name="sender" code="sndr" type="text" access="r" description="The sender of the message"/>
        <property name="read status" code="isrd" type="boolean" description="Indicates whether the message is read or not"/>
        <property name="mailbox" code="mbxp" type="mailbox" description="The mailbox in which this message is filed"/>
        <property name="message signature" code="tnrg" description="The signature of the message"><type type="signature"/><type type="missing value"/></property>
        <property name="html content" code="htda" type="text" access="w" hidden="yes" description="Does nothing at all (deprecated)"/>
        <responds-to command="send"/>
        <responds-to command="close"/>
        </class>
        <class-extension extends="application" description="Mail's top level scripting object."><element type="outgoing message"/><element type="mailbox"/><element type="ldap server" hidden="yes"/></class-extension>
        </suite>
        </dictionary>
        """

    /// Recorded from `/usr/bin/sdef /Applications/Spotify.app` — the app's own suite only
    /// (its Standard Suite stub is at the end of the real file and adds nothing here).
    static let spotifyExcerpt = """
        <?xml version="1.0" encoding="UTF-8"?>
        <dictionary title="Dictionary">
        <suite name="Spotify Suite" code="spfy" description="Spotify specific classes.">
        <enumeration name="ePlS" code="ePlS"><enumerator name="stopped" code="kPSS"/><enumerator name="playing" code="kPSP"/><enumerator name="paused" code="kPSp"/></enumeration>
        <value-type name="image data" code="spIm" description="Image data in TIFF format."><cocoa class="NSImage"/></value-type>
        <class name="application" code="capp" description="The Spotify application.">
        <access-group identifier="com.spotify.playback"/>
        <cocoa class="SPTClientApplication"/>
        <property name="current track" code="pTrk" description="The current playing track." type="track" access="r"><cocoa key="currentTrack"/></property>
        <property name="sound volume" code="pVol" description="The sound output volume (0 = minimum, 100 = maximum)" type="integer"><cocoa key="soundVolume"/></property>
        <property name="player state" code="pPlS" description="Is Spotify stopped, paused, or playing?" type="ePlS" access="r"><cocoa key="playerState"/></property>
        <property name="repeating" code="pRep" description="Is repeating on or off?" type="boolean"><cocoa key="repeat"/></property>
        </class>
        <class name="track" code="spTr" description="A Spotify track." plural="tracks">
        <access-group identifier="com.spotify.library" access="r"/>
        <cocoa class="SPTAppleScriptTrack"/>
        <property name="artist" code="pArt" description="The artist of the track." type="text" access="r"><cocoa key="artist"/></property>
        <property name="album" code="pAlb" description="The album of the track." type="text" access="r"><cocoa key="album"/></property>
        <property name="duration" code="pDur" description="The length of the track in seconds." type="integer" access="r"><cocoa key="duration"/></property>
        <property name="starred" code="spSt" description="Is the track starred?" type="boolean" access="r"><cocoa key="starred"/></property>
        <property name="id" code="ID  " description="The ID of the item." type="text" access="r"><cocoa key="applescriptID"/></property>
        <property name="name" code="pnam" description="The name of the track." type="text" access="r"><cocoa key="title"/></property>
        <property name="artwork url" code="aUrl" description="The URL of the track%apos;s album cover." type="text" access="r"><cocoa key="coverURL"/></property>
        <property name="spotify url" code="spur" description="The URL of the track." type="text"><cocoa key="spotifyURL"/></property>
        </class>
        <command name="next track" code="spfyNext" description="Skip to the next track."><access-group identifier="com.spotify.playback"/><cocoa class="SPNextTrackScriptCommand"/></command>
        <command name="previous track" code="spfyPrev" description="Skip to the previous track."><access-group identifier="com.spotify.playback"/></command>
        <command name="playpause" code="spfyPlPs" description="Toggle play/pause."><access-group identifier="com.spotify.playback"/></command>
        <command name="pause" code="spfyPaus" description="Pause playback."><access-group identifier="com.spotify.playback"/></command>
        <command name="play" code="spfyPlay" description="Resume playback."><access-group identifier="com.spotify.playback"/></command>
        <command name="play track" code="spfyPCtx" description="Start playback of a track in the given context."><access-group identifier="com.spotify.playback"/><direct-parameter description="the URI of the track to play" type="text"/><parameter name="in context" code="cotx" description="the URI of the context to play in" type="text" optional="yes"><cocoa key="context"/></parameter></command>
        </suite>
        </dictionary>
        """

    /// Recorded from `/usr/bin/sdef /System/Applications/Music.app` (excerpt).
    static let musicExcerpt = """
        <?xml version="1.0" encoding="UTF-8"?>
        <dictionary title="Dictionary">
        <suite name="Music Library" code="hook" description="Play and stop audio.">
        <command name="play" code="hookPlay" description="play the current track or the specified track or file."><direct-parameter type="track" optional="yes"/></command>
        <command name="stop" code="hookStop" description="stop playback"/>
        <class name="source" code="sour"><element type="playlist"/></class>
        <class name="playlist" code="cPly" inherits="item" plural="playlists" description="a list of tracks/streams"><element type="track"/><property name="name" code="pnam" type="text" description="the name of the playlist"/><property name="smart" code="cSrt" type="boolean" access="r"/></class>
        <class name="track" code="cTrk" description="playable audio source" inherits="item" plural="tracks"><property name="name" code="pnam" type="text"/><property name="album" type="text" access="r"/><property name="duration" type="integer" access="r"/><property name="finish" type="real"/><property name="enabled" type="boolean"/></class>
        </suite>
        </dictionary>
        """

    // MARK: Mail

    @Test func mailMessageClassReadsFromItsOwnSuite() throws {
        let dictionary = AppSdefParser.parse(
            Self.mailExcerpt, bundleID: "com.apple.mail", appName: "Mail", version: "17")
        let message = try #require(dictionary.class(named: "message"))
        #expect(message.suite == "Mail Framework")
        #expect(message.readablePropertyNames.contains("subject"))
        #expect(message.readablePropertyNames.contains("sender"))
        #expect(message.readablePropertyNames.contains("read status"))
        #expect(!message.elementTypes.isEmpty)
        // The nested `<type>`s are what the property's type is.
        let signature = try #require(message.property(named: "message signature"))
        #expect(signature.type == "signature")
        // A hidden property is not in the manifest at all — the query builder can
        // never be pointed at something the app does not expose.
        #expect(message.property(named: "html content") == nil)
    }

    @Test func mailCommandsClassifyForTheGate() throws {
        let dictionary = AppSdefParser.parse(
            Self.mailExcerpt, bundleID: "com.apple.mail", appName: "Mail", version: "17")
        // Anything that sends is outbound — the rung never renders these.
        #expect(dictionary.command(named: "send")?.verbClass == .outbound)
        #expect(dictionary.command(named: "reply")?.verbClass == .outbound)
        #expect(dictionary.command(named: "forward")?.verbClass == .outbound)
        // Local state changes ask.
        #expect(dictionary.command(named: "synchronize")?.verbClass == .write)
        #expect(dictionary.command(named: "check for new mail")?.verbClass == .write)
        // A pure extraction reads.
        #expect(dictionary.command(named: "extract name from")?.verbClass == .read)
        // The hidden duplicate is not learned; the Standard Suite's delete is.
        #expect(
            dictionary.command(named: "delete")?.suite == "Standard Suite")
    }

    @Test func mailClassExtensionMergesIntoTheApplicationClass() throws {
        let dictionary = AppSdefParser.parse(
            Self.mailExcerpt, bundleID: "com.apple.mail", appName: "Mail", version: "17")
        // The Standard application class + Mail's extension elements land in one class.
        let application = try #require(dictionary.class(named: "application"))
        #expect(application.suite == "Standard Suite")
        #expect(application.elementTypes.contains("mailbox"))
        #expect(application.elementTypes.contains("outgoing message"))
        // Hidden inside a class-extension drops the same as anywhere else.
        #expect(!application.elementTypes.contains("ldap server"))
    }

    @Test func mailRespondsToSurvives() throws {
        let dictionary = AppSdefParser.parse(
            Self.mailExcerpt, bundleID: "com.apple.mail", appName: "Mail", version: "17")
        let message = try #require(dictionary.class(named: "message"))
        #expect(message.respondsTo.contains("send"))
        #expect(message.respondsTo.contains("close"))
    }

    // MARK: Spotify

    @Test func spotifyScoresReadPerClassAndCommandShape() throws {
        let dictionary = AppSdefParser.parse(
            Self.spotifyExcerpt, bundleID: "com.spotify.client", appName: "Spotify",
            version: "1.2")
        let track = try #require(dictionary.class(named: "track"))
        #expect(track.plural == "tracks")
        #expect(track.readablePropertyNames.contains("name"))
        #expect(track.readablePropertyNames.contains("artist"))
        #expect(track.readablePropertyNames.contains("spotify url"))
        #expect(track.writablePropertyNames.contains("spotify url"))
        // The read-only flag survives: a read may not ask for a refused field?
        // star is access="r" and cannot be written.
        #expect(track.writablePropertyNames.contains("starred") == false)

        let application = try #require(dictionary.class(named: "application"))
        #expect(application.suite == "Spotify Suite")
        #expect(application.property(named: "current track") != nil)
        // Playback verbs are writes: they change local state and ask first.
        #expect(dictionary.command(named: "play")?.verbClass == .write)
        #expect(dictionary.command(named: "playpause")?.verbClass == .write)
        #expect(dictionary.command(named: "next track")?.verbClass == .write)
        // `play track` carries a direct parameter and a named one.
        let playTrack = try #require(dictionary.command(named: "play track"))
        #expect(playTrack.verbClass == .write)
        #expect(playTrack.directType == "text")
        #expect(playTrack.parameterNames.contains("in context"))
    }

    // MARK: Music

    @Test func musicTracksAndPlaylistsParse() throws {
        let dictionary = AppSdefParser.parse(
            Self.musicExcerpt, bundleID: "com.apple.Music", appName: "Music", version: "1.7")
        #expect(dictionary.class(named: "track") != nil)
        #expect(dictionary.class(named: "playlist") != nil)
        #expect(dictionary.class(named: "source")?.elementTypes == ["playlist"])
        let finish = try #require(dictionary.class(named: "track")?.property(named: "finish"))
        #expect(finish.type == "real")
        #expect(dictionary.command(named: "play")?.verbClass == .write)
        #expect(dictionary.command(named: "stop")?.verbClass == .write)
    }

    // MARK: Tolerance

    @Test func brokenXMLStillYieldsWhatWasRead() {
        // Tolerance: trailing garbage after a complete dictionary leaves the parsed
        // classes standing — a half-learned manifest still names what it knows.
        let broken = """
            <dictionary title="T"><suite name="X">
            <class name="item"><property name="a" type="text"/></class>
            <class name="junk"><property name="b" type="integer"/></class>
            </suite></dictionary><not-really/>
            """
        let dictionary = AppSdefParser.parse(
            broken, bundleID: "com.broken.app", appName: "Broken", version: "1")
        #expect(dictionary.class(named: "item")?.property(named: "a")?.type == "text")
        #expect(dictionary.class(named: "junk") != nil)
    }

    @Test func emptyXMLYieldsAnEmptyManifest() {
        let dictionary = AppSdefParser.parse(
            "", bundleID: "com.broken.app", appName: "Broken", version: "1")
        #expect(dictionary.isEmpty)
        #expect(dictionary.summarySentence.contains("0 scripting classes"))
    }

    @Test func summaryNamesCountsAndWrites() {
        let dictionary = AppSdefParser.parse(
            Self.spotifyExcerpt, bundleID: "com.spotify.client", appName: "Spotify",
            version: "1.2")
        let summary = dictionary.summarySentence
        #expect(summary.contains("Learned 2 scripting classes"))
        #expect(summary.contains("6 commands"))
        #expect(summary.contains("6 are writes that ask first"))
    }

    @Test func classLookupPrefersTheAppSuite() throws {
        // Two suites declare "application": the app's own (with its properties)
        // wins, because the Standard stub carries nothing of the app.
        let dictionary = AppSdefParser.parse(
            Self.spotifyExcerpt, bundleID: "com.spotify.client", appName: "Spotify",
            version: "1.2")
        let application = try #require(dictionary.class(named: "application"))
        #expect(application.property(named: "current track") != nil)
        #expect(application.property(named: "sound volume")?.type == "integer")
        #expect(application.property(named: "sound volume")?.isReadOnly == false)
        #expect(application.property(named: "player state")?.isReadOnly == true)
    }
}
