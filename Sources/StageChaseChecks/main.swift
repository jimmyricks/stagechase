import Foundation
import StageChaseCore

@main
enum StageChaseChecks {
    static func main() throws {
        try checkProjectCodec()
        try checkProjectDefaultsForOlderDocuments()
        try checkLiveSnapshot()
        try checkProjectValidation()
        try checkOSCMessage()
        try checkOSCTrigger()
        try checkAddressValidation()
        try checkPresetImporter()
        try checkCATEELStructure()
        try checkProvidedPresetIfSet()
        print("All StageChase checks passed.")
    }

    private static func checkProjectCodec() throws {
        let project = StageChaseProject.starter()
        let decoded = try ProjectCodec.decode(ProjectCodec.encode(project))
        try require(decoded.schemaVersion == StageChaseProject.currentSchemaVersion, "project schema round trip")
        try require(decoded.slices == project.slices, "slice round trip")
        try require(decoded.sequences == project.sequences, "sequence round trip")
        try require(decoded.widgets.count == 4, "widget round trip")
        try require(decoded.sequences[0].stepDuration == 0.45, "playback setting round trip")
    }

    private static func checkProjectValidation() throws {
        var project = StageChaseProject.starter()
        project.sequences[0].steps[0].enabledSliceIDs = ["missing"]
        do {
            try project.validate()
            throw CheckFailure.failed("unknown slice references must be rejected")
        } catch ProjectError.unknownSliceReference {
        }
    }

    private static func checkLiveSnapshot() throws {
        let snapshot = String(decoding: try LiveProjectSnapshot.encode(.starter()), as: UTF8.self)
        try require(snapshot.hasPrefix("STAGECHASE 1\n"), "live snapshot header")
        try require(snapshot.contains("\n12\n4\n"), "live snapshot slices and geometry")
    }

    private static func checkProjectDefaultsForOlderDocuments() throws {
        var object = try JSONSerialization.jsonObject(with: ProjectCodec.encode(.starter())) as! [String: Any]
        var sequences = object["sequences"] as! [[String: Any]]
        for index in sequences.indices {
            sequences[index].removeValue(forKey: "direction")
            sequences[index].removeValue(forKey: "stepDuration")
            sequences[index].removeValue(forKey: "scaling")
            sequences[index].removeValue(forKey: "echoes")
        }
        object["sequences"] = sequences
        var widgets = object["widgets"] as! [[String: Any]]
        for index in widgets.indices { widgets[index].removeValue(forKey: "width") }
        object["widgets"] = widgets
        let decoded = try ProjectCodec.decode(JSONSerialization.data(withJSONObject: object))
        try require(decoded.sequences[0].direction == .forward, "older sequence direction default")
        try require(decoded.sequences[0].stepDuration == 0.45, "older sequence speed default")
        try require(decoded.widgets[0].width == .compact, "older widget width default")
    }

    private static func checkOSCMessage() throws {
        let packet = try OSCMessage.float(address: "/composition/master", value: 0.5)
        let expectedAddress = Array("/composition/master".utf8) + [0]
        try require(Array(packet.prefix(expectedAddress.count)) == expectedAddress, "OSC address padding")
        try require(Array(packet.suffix(8).prefix(4)) == Array(",f\0\0".utf8), "OSC float type tag")
        try require(Array(packet.suffix(4)) == [0x3f, 0x00, 0x00, 0x00], "OSC big-endian float")
    }

    private static func checkAddressValidation() throws {
        try require(OSCAddress.isValid("/composition/layers/1/video/opacity"), "valid OSC address")
        try require(!OSCAddress.isValid("composition/master"), "leading slash validation")
        try require(!OSCAddress.isValid("/composition//master"), "empty address segment validation")
        try require(!OSCAddress.isValid("/composition/master value"), "whitespace validation")
    }

    private static func checkOSCTrigger() throws {
        let packet = try OSCMessage.trigger(address: "/composition/connectnextcolumn")
        try require(Array(packet.suffix(8).prefix(4)) == Array(",i\0\0".utf8), "OSC trigger type tag")
        try require(Array(packet.suffix(4)) == [0, 0, 0, 1], "OSC trigger value")
    }

    private static func checkPresetImporter() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <XmlState>
          <ScreenSetup>
            <screens>
              <Screen name="Main">
                <Slices>
                  <Slice uniqueId="panel-a" name="Panel A">
                    <Shape>
                      <Vertex x="0.1" y="0.2"/>
                      <Vertex x="0.8" y="0.2"/>
                      <Vertex x="0.8" y="0.9"/>
                      <Vertex x="0.1" y="0.9"/>
                    </Shape>
                  </Slice>
                </Slices>
              </Screen>
            </screens>
          </ScreenSetup>
        </XmlState>
        """
        let imported = try AdvancedOutputImporter.importData(Data(xml.utf8))
        try require(imported.slices.count == 1, "slice import")
        try require(imported.slices[0].id == "panel-a", "stable slice id")
        try require(imported.slices[0].name == "Panel A", "slice name")
        try require(imported.slices[0].screenName == "Main", "screen name")
        try require(imported.slices[0].points.count == 4, "slice polygon")
        do {
            _ = try AdvancedOutputImporter.importData(Data("<Root/>".utf8))
            throw CheckFailure.failed("importer should reject a preset without slices")
        } catch AdvancedOutputImportError.noSlices {
        }
    }

    private static func checkCATEELStructure() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <XmlState name="CATEEL">
          <ScreenSetup>
            <CurrentCompositionTextureSize width="1920" height="1080"/>
            <screens><Screen name="Screen 1"/></screens>
            <layers>
              <Slice uniqueId="slice-a">
                <Params name="Common"><Param name="Name" value="RUNWAY 2"/></Params>
                <InputRect orientation="0">
                  <v x="854.5" y="787.5"/>
                  <v x="1434.1" y="787.5"/>
                  <v x="1434.1" y="1004.6"/>
                  <v x="854.5" y="1004.6"/>
                </InputRect>
                <OutputRect orientation="0">
                  <v x="1648.8" y="1647.6"/>
                  <v x="2843.8" y="1647.6"/>
                  <v x="2843.8" y="2095.4"/>
                  <v x="1648.8" y="2095.4"/>
                </OutputRect>
              </Slice>
            </layers>
          </ScreenSetup>
        </XmlState>
        """

        let imported = try AdvancedOutputImporter.importData(Data(xml.utf8))
        try require(imported.canvasWidth == 1920, "CATEEL composition width")
        try require(imported.canvasHeight == 1080, "CATEEL composition height")
        try require(imported.slices.count == 1, "CATEEL slice count")
        try require(imported.slices[0].name == "RUNWAY 2", "CATEEL slice name")
        try require(imported.slices[0].screenName == "Screen 1", "CATEEL screen fallback")
        try require(abs(imported.slices[0].points[0].x - 854.5 / 1920) < 0.000001, "CATEEL uses InputRect coordinates")
        try require(abs(imported.slices[0].points[0].y - 787.5 / 1080) < 0.000001, "CATEEL input Y coordinate")
    }

    private static func checkProvidedPresetIfSet() throws {
        guard let path = ProcessInfo.processInfo.environment["STAGECHASE_PRESET_PATH"] else { return }
        let imported = try AdvancedOutputImporter.importData(Data(contentsOf: URL(fileURLWithPath: path)))
        try require(imported.slices.count == 5, "provided CATEEL slice count")
        try require(imported.canvasWidth == 1920, "provided CATEEL canvas width")
        try require(imported.canvasHeight == 1080, "provided CATEEL canvas height")
        print("Imported \(imported.slices.count) slices from \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw CheckFailure.failed(name) }
    }
}

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let name): "Check failed: \(name)"
        }
    }
}
