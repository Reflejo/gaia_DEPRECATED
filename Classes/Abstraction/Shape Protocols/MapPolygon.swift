/**
 MapPolygon defines a polygon that appears on the map. A polygon (like a polyline) defines a
 series of connected coordinates in an ordered sequence; additionally, polygons form a closed loop
 and define a filled region.
 */
public protocol MapPolygon: MapShape {

    /// The width of the polygon outline in screen points.
    var strokeWidth: CGFloat { get set }

    /// The color of the polygon outline.
    var strokeColor: UIColor? { get set }

    /// The fill color of the polygon.
    var fillColor: UIColor? { get set }

    /**
     Creates a `MapPolygon` from an encoded path that describes the polygon.

     - parameter encodedPath: The path represented using Google's Encoded Polyline Algorithm Format.

     - returns: the newly created `MapPolygon` composed from the given path.
     */
    static func fromEncodedPath(encodedPath: String) -> MapPolygon
}
