import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "prayerTimes"

    // === Coordinate lookup ===
    // The only network the plugin ever touches, and only when the button is
    // pressed. It proposes rather than applies: an IP lookup frequently resolves
    // to the ISP's exchange rather than to where you are -- measured here at
    // 163 km out, which moves every prayer by three to six minutes -- so
    // overwriting good coordinates with it unattended would be a downgrade.
    property bool detecting: false
    property real detectStartedAt: 0
    property string detectStatus: ""
    property bool detectFailed: false
    property real foundLat: NaN
    property real foundLon: NaN
    property string foundPlace: ""
    readonly property bool hasCandidate: !isNaN(foundLat) && !isNaN(foundLon)

    function currentCoord(key) {
        return parseFloat(String(root.loadValue(key, "0")).trim())
    }

    function distanceKm(lat1, lon1, lat2, lon2) {
        var r = Math.PI / 180
        var a = Math.sin((lat2 - lat1) * r / 2) * Math.sin((lat2 - lat1) * r / 2)
              + Math.cos(lat1 * r) * Math.cos(lat2 * r)
              * Math.sin((lon2 - lon1) * r / 2) * Math.sin((lon2 - lon1) * r / 2)
        return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(a)))
    }

    function detectLocation() {
        var now = Date.now()
        // Guard a double click without latching forever if a request hangs.
        if (root.detecting && now - root.detectStartedAt < 15000)
            return
        root.detecting = true
        root.detectStartedAt = now
        root.detectFailed = false
        root.detectStatus = ""
        root.foundLat = NaN
        root.foundLon = NaN

        // ipinfo first: it answered when ipapi.co returned nothing usable.
        root.lookup("https://ipinfo.io/json", function (j) {
            if (!j.loc)
                return null
            var parts = String(j.loc).split(",")
            return { lat: Number(parts[0]), lon: Number(parts[1]),
                     place: root.placeName([j.city, j.region, j.country]) }
        }, function () {
            root.lookup("https://ipapi.co/json/", function (j) {
                if (j.latitude === undefined || j.longitude === undefined)
                    return null
                return { lat: Number(j.latitude), lon: Number(j.longitude),
                         place: root.placeName([j.city, j.region, j.country_name]) }
            }, function () {
                root.detecting = false
                root.detectFailed = true
                root.detectStatus = "No location service could be reached."
            })
        })
    }

    function placeName(parts) {
        var out = []
        for (var i = 0; i < parts.length; i++)
            if (parts[i]) out.push(parts[i])
        return out.join(", ")
    }

    function lookup(url, parse, onFail) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            var found = null
            if (xhr.status === 200) {
                try {
                    found = parse(JSON.parse(xhr.responseText))
                } catch (e) {
                    found = null
                }
            }
            if (found && isFinite(found.lat) && isFinite(found.lon)
                    && Math.abs(found.lat) <= 90 && Math.abs(found.lon) <= 180)
                root.presentCandidate(found)
            else
                onFail()
        }
        xhr.open("GET", url)
        xhr.send()
    }

    function presentCandidate(found) {
        root.detecting = false
        root.detectFailed = false
        root.foundLat = found.lat
        root.foundLon = found.lon
        root.foundPlace = found.place
        root.detectStatus = (found.place ? found.place + "  ·  " : "")
                          + found.lat.toFixed(4) + ", " + found.lon.toFixed(4)
    }

    function applyCandidate() {
        if (!root.hasCandidate)
            return
        // Four decimals is about eleven metres; more would be false precision
        // on a number this approximate to begin with.
        root.saveValue("lat", root.foundLat.toFixed(4))
        root.saveValue("lon", root.foundLon.toFixed(4))
        root.detectStatus = "Applied " + root.foundLat.toFixed(4) + ", " + root.foundLon.toFixed(4)
        root.foundLat = NaN
        root.foundLon = NaN
    }

    StyledText {
        width: parent.width
        text: "Prayer Times Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Prayer times are computed on this machine from your coordinates. Nothing is fetched over the network."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SelectionSetting {
        settingKey: "method"
        label: "Calculation Method"
        description: "Twilight angles defining dawn and nightfall. These are conventions, not physics -- pick the one your local mosque follows."
        options: [
            { label: "Jafari / Shia Ithna-Ashari", value: "0" },
            { label: "University of Islamic Sciences, Karachi", value: "1" },
            { label: "Islamic Society of North America", value: "2" },
            { label: "Muslim World League", value: "3" },
            { label: "Umm Al-Qura University, Makkah", value: "4" },
            { label: "Egyptian General Authority of Survey", value: "5" },
            { label: "Institute of Geophysics, University of Tehran", value: "7" },
            { label: "Gulf Region", value: "8" },
            { label: "Kuwait", value: "9" },
            { label: "Qatar", value: "10" },
            { label: "Majlis Ugama Islam Singapura, Singapore", value: "11" },
            { label: "Union Organization islamic de France", value: "12" },
            { label: "Diyanet İşleri Başkanlığı, Turkey", value: "13" },
            { label: "Spiritual Administration of Muslims of Russia", value: "14" },
            { label: "Dubai (experimental)", value: "16" },
            { label: "JAKIM, Malaysia", value: "17" },
            { label: "Tunisia", value: "18" },
            { label: "Algeria", value: "19" },
            { label: "KEMENAG, Indonesia", value: "20" },
            { label: "Morocco", value: "21" },
            { label: "Comunidade Islamica de Lisboa", value: "22" },
            { label: "Ministry of Awqaf, Jordan", value: "23" }
        ]
        defaultValue: "2"
    }

    SelectionSetting {
        settingKey: "school"
        label: "Asr Calculation School"
        description: "Juristic school used to calculate the Asr prayer time."
        options: [
            { label: "Shafi (Default)", value: "0" },
            { label: "Hanafi", value: "1" }
        ]
        defaultValue: "0"
    }

    SelectionSetting {
        settingKey: "highLat"
        label: "High Latitude Rule"
        description: "Above roughly 48 degrees the sun may never sink far enough below the horizon for dawn or nightfall to occur in summer, leaving Fajr and Isha undefined. This chooses how to estimate them."
        options: [
            { label: "Angle based (default)",  value: "angle" },
            { label: "Middle of the night",    value: "nightmiddle" },
            { label: "One seventh of night",   value: "seventh" },
            { label: "None (leave undefined)", value: "none" }
        ]
        defaultValue: "angle"
    }

    SelectionSetting {
        settingKey: "hijriOffset"
        label: "Hijri Date Adjustment"
        description: "The Hijri date is computed arithmetically, which can differ by a day from a locally moonsighted calendar. Shift it to match your mosque."
        options: [
            { label: "-2 days", value: "-2" },
            { label: "-1 day",  value: "-1" },
            { label: "No adjustment", value: "0" },
            { label: "+1 day",  value: "1" },
            { label: "+2 days", value: "2" }
        ]
        defaultValue: "0"
    }

    StyledRect {
        width: parent.width
        height: locationColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: locationColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Location"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StringSetting {
                settingKey: "lat"
                label: "Latitude"
                description: "Example: -6.2000"
                defaultValue: "0.0"
            }

            StringSetting {
                settingKey: "lon"
                label: "Longitude"
                description: "Example: 106.8166"
                defaultValue: "0.0"
            }

            Column {
                width: parent.width
                spacing: Theme.spacingXS

                StyledRect {
                    width: parent.width
                    height: 38
                    radius: Theme.cornerRadius
                    color: detectArea.containsMouse
                           ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.22)
                           : Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.12)

                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            name: root.detecting ? "sync" : "my_location"
                            size: Theme.iconSize - 6
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.detecting ? "Looking up…" : "Detect my coordinates"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: detectArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.detectLocation()
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.detectStatus !== ""
                    text: root.detectStatus
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: root.hasCandidate ? Font.Medium : Font.Normal
                    color: root.detectFailed ? Theme.error : Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                // How far the proposal sits from what is configured, which is the
                // number that tells you whether to trust it.
                StyledText {
                    width: parent.width
                    visible: root.hasCandidate
                    text: {
                        if (!root.hasCandidate)
                            return ""
                        var d = root.distanceKm(root.currentCoord("lat"), root.currentCoord("lon"),
                                                root.foundLat, root.foundLon)
                        if (!isFinite(d))
                            return "No current coordinates to compare against."
                        if (d < 1)
                            return "Within a kilometre of your current setting."
                        return Math.round(d) + " km from your current setting"
                             + (d > 25 ? " — check this before applying." : ".")
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: {
                        var d = root.hasCandidate
                              ? root.distanceKm(root.currentCoord("lat"), root.currentCoord("lon"),
                                                root.foundLat, root.foundLon)
                              : 0
                        return (isFinite(d) && d > 25) ? Theme.warning : Theme.surfaceVariantText
                    }
                    wrapMode: Text.WordWrap
                }

                StyledRect {
                    width: parent.width
                    height: 34
                    visible: root.hasCandidate
                    radius: Theme.cornerRadius
                    color: applyArea.containsMouse
                           ? Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.16)
                           : Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.08)

                    StyledText {
                        anchors.centerIn: parent
                        text: "Use these coordinates"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    MouseArea {
                        id: applyArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.applyCandidate()
                    }
                }

                StyledText {
                    width: parent.width
                    text: "The one time this plugin uses the network. It locates your public IP, which often resolves to your provider's exchange rather than your town — tested here it landed 163 km away, enough to move every prayer by several minutes. It proposes; you decide. A VPN will report wherever it exits."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }

        }
    }

    StyledRect {
        width: parent.width
        height: displayColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: displayColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Display"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            ToggleSetting {
                settingKey: "showPillProgress"
                label: "Progress Rule"
                description: "Draw a thin rule beneath the bar widget showing how much of the current window has passed"
                defaultValue: true
            }

            ToggleSetting {
                settingKey: "iconOnly"
                label: "Symbol Only"
                description: "Hide the countdown in the bar and show only the prayer's symbol"
                defaultValue: false
            }

            ToggleSetting {
                settingKey: "showSeconds"
                label: "Show Seconds"
                description: "Count down to the second rather than the minute"
                defaultValue: false
            }

            ToggleSetting {
                settingKey: "use12H"
                label: "12-Hour Format"
                description: "Display times in 12-hour format instead of 24-hour"
                defaultValue: false
            }
        }
    }

    StyledRect {
        width: parent.width
        height: aboutColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surface

        Column {
            id: aboutColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                spacing: Theme.spacingM

                DankIcon {
                    name: "info"
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "About Prayer Times"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                text: "Prayer times are computed locally from the sun's position — no network requests, no rate limits, and your coordinates never leave this machine. The one exception is the Detect button above, which asks a lookup service where your IP is, only when pressed, and which proposes rather than applies.\n\n• Each prayer as a window: when it opens, when it closes, how long is left\n• Islamic midnight and the Hijri date\n• 22 calculation methods, both Asr schools, high-latitude handling\n\nForked from the Prayer Times plugin by muadz (github.com/muadzmo/prayertimes). The local computation, prayer windows and interface are this fork's own work."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                width: parent.width
                lineHeight: 1.4
            }
        }
    }
}
