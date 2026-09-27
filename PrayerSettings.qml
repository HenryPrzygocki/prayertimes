import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "prayerTimes"

    // === Coordinate lookup ===
    // Search by place name, not by IP. An IP lookup answers "where does my
    // traffic leave the network", which behind a VPN is a different question
    // from "where am I", and even without one it resolves to the provider's
    // exchange -- measured 163 km out from here. A name search asks the question
    // actually being asked, and a VPN cannot affect the answer.
    property var placeResults: []
    property bool searching: false
    property real searchStartedAt: 0
    property string searchStatus: ""

    function placeName(parts) {
        var out = []
        for (var i = 0; i < parts.length; i++)
            if (parts[i]) out.push(parts[i])
        return out.join(", ")
    }

    function searchPlace(query) {
        var q = String(query).trim()
        root.placeResults = []
        if (q.length < 2) {
            root.searchStatus = ""
            return
        }
        var now = Date.now()
        if (root.searching && now - root.searchStartedAt < 15000)
            return
        root.searching = true
        root.searchStartedAt = now
        root.searchStatus = ""

        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            root.searching = false
            if (xhr.status !== 200) {
                root.searchStatus = "Could not reach the place directory."
                return
            }
            var found = []
            try {
                var hits = JSON.parse(xhr.responseText).results || []
                for (var i = 0; i < hits.length; i++) {
                    var h = hits[i]
                    if (!isFinite(h.latitude) || !isFinite(h.longitude))
                        continue
                    found.push({ label: root.placeName([h.name, h.admin1, h.country]),
                                 lat: h.latitude, lon: h.longitude,
                                 population: h.population || 0 })
                }
            } catch (e) {
                root.searchStatus = "Could not read the response."
                return
            }
            // The directory returns matches in its own order, which buried a town
            // of sixty thousand below several of a few thousand. Largest first is
            // the better guess at which one was meant.
            found.sort(function (a, b) { return b.population - a.population })
            root.placeResults = found.slice(0, 8)
            root.searchStatus = found.length > 0 ? "" : "Nothing found for \u201c" + q + "\u201d."
        }
        xhr.open("GET", "https://geocoding-api.open-meteo.com/v1/search"
                      + "?count=10&language=en&format=json&name=" + encodeURIComponent(q))
        xhr.send()
    }

    function applyPlace(place) {
        // Four decimals is about eleven metres, far finer than any prayer time
        // resolves to.
        root.saveValue("lat", place.lat.toFixed(4))
        root.saveValue("lon", place.lon.toFixed(4))
        root.placeResults = []
        root.searchStatus = "Set to " + place.label + "  \u00b7  "
                          + place.lat.toFixed(4) + ", " + place.lon.toFixed(4)
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
                description: "Example: 32.6099"
                defaultValue: ""
            }

            StringSetting {
                settingKey: "lon"
                label: "Longitude"
                description: "Example: -85.4808"
                defaultValue: ""
            }

            Column {
                width: parent.width
                spacing: Theme.spacingXS

                StyledText {
                    width: parent.width
                    text: "Or find it by name"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                DankTextField {
                    id: placeField
                    width: parent.width
                    placeholderText: root.searching ? "Searching…" : "Town or city, then Enter"
                    onEditingFinished: root.searchPlace(text)
                }

                StyledText {
                    width: parent.width
                    visible: root.searchStatus !== ""
                    text: root.searchStatus
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: root.placeResults

                    delegate: StyledRect {
                        required property var modelData
                        width: placeField.width
                        height: 38
                        radius: Theme.cornerRadius
                        color: hitArea.containsMouse
                               ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18)
                               : Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.06)

                        StyledText {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: coords.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        StyledText {
                            id: coords
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.lat.toFixed(2) + ", " + modelData.lon.toFixed(2)
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }

                        MouseArea {
                            id: hitArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.applyPlace(modelData)
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: "Searches a place directory by name — it never looks at your IP, so a VPN makes no difference. Matches are listed largest first; pick the right one and the coordinates above are filled in."
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
                text: "Prayer times are computed locally from the sun's position — no network requests, no rate limits, and your coordinates never leave this machine. The one exception is the place search above, which asks a directory for a town's coordinates when you search — by name, never by IP.\n\n• Each prayer as a window: when it opens, when it closes, how long is left\n• Islamic midnight and the Hijri date\n• 22 calculation methods, both Asr schools, high-latitude handling\n\nForked from the Prayer Times plugin by muadz (github.com/muadzmo/prayertimes). The local computation, prayer windows and interface are this fork's own work."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                width: parent.width
                lineHeight: 1.4
            }
        }
    }
}
