import XCTest
import PlanariumDomain
@testable import PlanariumPresets
final class SurfaceSupervisorReviewFindingsTests: XCTestCase {
 private func make() throws -> (InstrumentDocument,SpatialSurface) {
  let routing=SpatialRouting(target:.midiCC(channel:0,controller:74),program:.continuous(minimum:0,maximum:1,directionDegrees:0,curve:.linear))
  let s=try SpatialSurface(presentation:.init(name:"rect",color:.orange),form:.shape(.rectangle(widthCm:40,heightCm:20),.init(xCm:0,yCm:100,rotationDegrees:90)),routings:[routing])
  let layer=SpatialDocumentLayer(id:UUID(),name:"L",color:.orange,isVisible:true,isActive:true,isLocked:false,isSoloed:false,cells:[],routings:[],cellOverrides:[:],surfaces:[s])
  return(InstrumentDocument(spatial:try .init(latticeVersion:.polarDeviceV2,layers:[layer],selectedLayerID:layer.id),revision:.init(session:UUID(),counter:1)),s)
 }
 func testEditorRefusesPresentationThatItsSavedReaderCannotRead() throws {
  let (doc,s)=try make()
  let edit=SurfaceEdit.setPresentation(surfaceID:s.id,.init(name:"seventeen",color:.orange,valueColors:Array(repeating:.green,count:17)))
  XCTAssertThrowsError(try SurfaceEditor.apply(edit,to:doc),"Seventeen colors must be refused before creating an unreadable V7 file")
  if let accepted=try? SurfaceEditor.apply(edit,to:doc) {
   let bytes=try PresetDocumentWriter.encode(.init(name:"Saved by own writer",document:accepted))
   switch PresetDocumentReader.read(bytes) {
   case .success: break
   case .failure(let error): XCTFail("Editor and writer accepted the presentation but own reader refuses it: \(error)")
   }
  }
 }
 func testResizeRefusesChangingShapeKindAndReinterpretingItsAxis() throws {
  let (doc,s)=try make()
  XCTAssertEqual(SurfaceAxis.directionDegrees(of:s.materializedRoutings()[0].program),90)
  let edit=SurfaceEdit.resizeSurface(id:s.id,shape:.ringSector(fromCm:40,toCm:60,fromDegrees:-30,toDegrees:30),transform:.identity)
  XCTAssertThrowsError(try SurfaceEditor.apply(edit,to:doc),"A resize must not silently replace local geometry by scanner-centered geometry")
  if let accepted=try? SurfaceEditor.apply(edit,to:doc) {
   let after=accepted.spatial.layers[0].surfaces[0]
   XCTAssertEqual(SurfaceAxis.directionDegrees(of:after.materializedRoutings()[0].program),90,"Resize reinterpreted the axis without an explicit axis edit")
  }
 }
}
