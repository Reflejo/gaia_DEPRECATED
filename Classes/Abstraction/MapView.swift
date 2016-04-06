import CoreLocation

private let kMinimumMovementThreshold = 10.0
private let kPinYCenterDelta: CGFloat = 26.0
private let kMaximumQueueSize = 3

typealias AnimationQueueElement = (camera: MapCameraUpdate, target: CLLocationCoordinate2D, silent: Bool,
                                   completion: (Bool -> Void)?)

public class MapView: UIView {

    private var animationsQueue: [AnimationQueueElement] = []
    private var queuedCompletion: (Bool -> Void)?
    private var performWithoutNotifying = false
    private var observedCenter = (center: kCLLocationCoordinate2DInvalid, zoom: Float(-1.0)) {
        didSet {
            if abs(self.observedCenter.zoom - oldValue.zoom) > FLT_EPSILON && !self.performWithoutNotifying {
                self.cameraZoomChange.notify(self.observedCenter.zoom, previousModel: oldValue.zoom)
            }

            if self.observedCenter.center != oldValue.center && !self.performWithoutNotifying {
                self.centerPositionChange.notify(self.observedCenter.center, previousModel: oldValue.center)
            }
        }
    }

    private lazy var underlyingMap: MapSDKProvider = {
        assert(Gaia.SDK == nil, "You need to specify a provider before using Gaia.")

        var map = Gaia.SDK!.provider.init(providerDelegate: self)
        map.rendering = false
        return map
    }()

    /// The currently set settings for the map.
    public var settings: MapSettings {
        get { return self.underlyingMap.configuration }
        set { self.underlyingMap.configuration = newValue }
    }

    /// This property holds the marker that is currently highlighted (the map center is inbetween the
    /// position of the marker and the radius of the asset).
    public private(set) var highlightedMarker: MapHighlightableMarker?

    /// Zoom level. Zoom uses an exponentional scale, where zoom 0 represents the entire world as a 256 x 256
    /// square. Each successive zoom level increases magnification by a factor of 2.
    public var zoom: Float { return self.underlyingMap.zoom }

    /// This property serves as the observer for the map center.
    /// use as: mapView.cameraPositionChange.observe { old, new in ... }
    public let cameraPositionChange = MapObservable<CLLocationCoordinate2D>()

    /// This property serves as the observer for the map zoom level.
    /// use as: mapView.cameraZoomChange.observe { old, new in ... }
    public let cameraZoomChange = MapObservable<Float>()

    /// This property serves as the observer for the map center.
    /// use as: mapView.centerPositionChange.observe { old, new in ... }
    public let centerPositionChange = MapObservable<CLLocationCoordinate2D>()

    /// This closure will be called when map's camera is about to be moved
    public var willMoveMap: ((isGesture: Bool, target: CLLocationCoordinate2D?) -> Void)?

    /// A boolean that indicates if the map is being move using a gesture recognizer.
    public var duringGesture: Bool { return self.underlyingMap.duringGesture }

    /// Number of touches on the screen for the running gesture.
    public var touchesInScreen: Int { return self.underlyingMap.touchesInScreen }

    /// A view showing legally required copyright notices, positioned at the bottom-right of the map view.
    public var attributionButton: UIView? { return self.underlyingMap.attributionButton }

    /// Whether the user's location is displayed on the map.
    public var myLocationEnabled: Bool {
        get { return self.underlyingMap.myLocationEnabled }
        set { self.underlyingMap.myLocationEnabled = newValue }
    }

    /// When set, the camera will automatically follow user positions
    public var cameraFollowsUser: Bool {
        get { return self.underlyingMap.cameraFollowsUser }
        set { self.underlyingMap.cameraFollowsUser = newValue }
    }

    /// The marker that is selected.  Setting this property selects a particular marker, showing an info
    /// window on it. If it's non-nil, setting it to nil deselects the marker, hiding the info window.
    public var selectedMarker: MapMarker? {
        get { return self.underlyingMap.selectedMapMarker }
        set { self.underlyingMap.selectedMapMarker = newValue }
    }

    /// The geo location of the center point of the map
    public var centerPosition: CLLocationCoordinate2D { return self.underlyingMap.centerPosition }

    /// Returns the screen points per meter for the current map projection, based on centerPosition
    public var projection: MapProjection { return self.underlyingMap.project }

    // MARK: - View life cycle

    public override func didMoveToWindow() {
        super.didMoveToWindow()

        if self.window != nil {
            self.insertSubview(self.underlyingMap.view, atIndex: 0)
            self.underlyingMap.rendering = true
        }
    }

    // MARK: - Generic map methods

    /**
     Sets or removes given icon from highlighted state.

     - parameter marker:      The marker to set (or resign) active.
     - parameter highlighted: A boolean indicating whether the mark will be set as highlighted or not.

     - returns: a boolean indicating if the operation was completed successfuly.
     */
    public func setMarker(marker: MapHighlightableMarker, highlighted: Bool) -> Bool {
        if !highlighted {
            self.highlightedMarker = self.highlightedMarker === marker ? nil : self.highlightedMarker
            return self.highlightedMarker === marker
        }

        if let markerPosition = self.highlightedMarker?.position where
            self.centerPosition.distanceTo(markerPosition) <= self.centerPosition.distanceTo(marker.position)
        {
            return marker === self.highlightedMarker
        }

        self.highlightedMarker?.highlighted = false
        self.highlightedMarker = marker
        return true
    }

    /**
     Add shape into the map view.

     - parameter shape: The shape to add to the receiver. The map view retains the MapShape object.
     */
    public func addShape(shape: MapShape) {
        self.underlyingMap.addShape(shape)
    }

    /**
     Removes an annotation from the map view, deselecting it if it is selected. Removing an annotation object
     dissociates it from the map view entirely, preventing it from being displayed on the map.

     - parameter shape: The shape to remove.
     */
    public func removeShape(shape: MapShape, animated: Bool = false) {
        self.underlyingMap.removeShape(shape, animated: animated)
    }

    // MARK: - Methods to implement by subclasses

    /**
     When padding is set we need to adjust the static pin y-center (animated).

     - parameter padding:  All map calculations will take this inset into consideration. If the padding is
                           not balanced, the visual center of the view will move as appropriate
     - parameter animated: When true, the padding delta will be animated by moving the map and the static pin
     */
    public func setPadding(padding: UIEdgeInsets, animated: Bool, alongWithAnimation: (() -> Void)? = nil) {
        self.underlyingMap.setPadding(padding, animated: animated, alongWithAnimation: alongWithAnimation)
    }

    /**
     Switches to navigation mode. This mode shows the streets labels bigger and replaces the blue dot for a
     navigation icon that follows the user's heading. Default implementation is a no-op.

     - parameter navigating: A boolean indicating if navigation mode should be enabled (true) or disabled
                             (false).
     */
    public func setNavigating(navigating: Bool) {
        self.underlyingMap.setNavigating(navigating)
    }

    /**
     Changes the camera according to |target|. The camera change is instantaneous (with no animation).

     - parameter target:   Location on the earth which the camera points
     - parameter silently: When true, the change on the centerPosition will not notify its observers.
     */
    public func setTarget(target: CLLocationCoordinate2D, silently: Bool = false) {
        let CameraUpdateType = Gaia.ProviderTypes.CameraUpdateType
        self.moveCamera(update: CameraUpdateType.withTarget(target), target: target, animated: false,
                        silently: silently)
    }

    /**
     Animates camera position for a particular target and zoom level. This will
     set the bearing and viewingAngle properties of this camera to zero defaults (i.e., directly
     facing the Earth's surface, with the top of the screen pointing north).

     - parameter target:     Location on the earth which the camera points
     - parameter zoom:       The zoom level near the center of the screen. By default we won't change the zoom
     - parameter silently:   When true, the change on the centerPosition will not notify its observers.
     - parameter completion: A closure that will be called when the map animation is done
     */
    public func animateToTarget(target: CLLocationCoordinate2D, zoom: Float? = nil, silently: Bool = false,
                                completion: (Bool -> Void)? = nil)
    {
        let zoomHasChanged = abs((zoom ?? self.zoom) - self.zoom) > FLT_EPSILON
        if target == self.centerPosition && !zoomHasChanged {
            completion?(false)
            return
        }

        let CameraUpdateType = Gaia.ProviderTypes.CameraUpdateType
        let cameraUpdate = zoom.map { CameraUpdateType.withTarget(target, zoom: $0) }
            ?? CameraUpdateType.withTarget(target)
        self.moveCamera(update: cameraUpdate, target: target, silently: silently, completion: completion)
    }

    /**
     Zooms the camera to the region of the map containing the given coordinates. When allowPan is false,
     we'll do it without panning the map.

     - parameter coordinates:        The array containing all the coordinates that need to be visible after
                                     zooming.
     - parameter silently:           When true, the change on the centerPosition will not notify its observers
     - parameter allowPan:           Optional boolean that defines whether the zoom will pan the map for the
                                     optional zoom (true) or keep the map center (false).
     - parameter offsetFactor:       Factor the centerPosition should be offset, ignored if no centerPosition
     - parameter minVisibleDistance: The minimum distance (in meters, diagonally) that should be visible when
                                     zooming. Can be used to not zoom in too far.
     - parameter maxVisibleDistance: The maximum distance (in meters, diagonally) that should be visible when
                                     zooming. Can be used to not zoom out too far.
     */
    public func zoomToRegion(thatFitsCoordinates coordinates: [CLLocationCoordinate2D],
                             silently: Bool = false, allowPan: Bool = true, offsetFactor: Double? = nil,
                             minVisibleDistance: CLLocationDistance = 0,
                             maxVisibleDistance: CLLocationDistance = CLLocationDistanceMax)
    {
        if coordinates.isEmpty {
            return
        }

        var bounds = CoordinateBounds(includingCoordinates: coordinates)

        // By default fitBounds method will pan the map to fit the given bounds. We need to do this
        // projection in order to keep the center position.
        if !allowPan {
            bounds = bounds.derive(self.centerPosition)

            // extend the bounds to allow the center of the map to be offset
            if let offsetFactor = offsetFactor {
                bounds = bounds.extendSouthEast(offsetFactor: offsetFactor)
            }
        }

        bounds = bounds.boundToDistance(min: minVisibleDistance, max: maxVisibleDistance)

        let CameraUpdateType = Gaia.ProviderTypes.CameraUpdateType
        self.moveCamera(update: CameraUpdateType.fitBounds(bounds), target: bounds.center, silently: silently)
    }

    /**
     Zooms camera to the minimum region containing all the given polylines.

     - parameter bounds:         Desired bounds to move the camera to
     - parameter silently:       When true, the final change on the map center will not notify its observers.
     - parameter completion:     A closure that will be called when the map animation is completed.
     */
    public func zoomToRegion(thatFitsBounds bounds: CoordinateBounds, silently: Bool = false,
                                            centerPosition: CLLocationCoordinate2D? = nil,
                                            completion: (Bool -> Void)? = nil)
    {
        let CameraUpdateType = Gaia.ProviderTypes.CameraUpdateType
        let translatedBounds = centerPosition.map(bounds.translateTo) ?? bounds
        self.moveCamera(update: CameraUpdateType.fitBounds(translatedBounds), target: bounds.center,
                        silently: silently, completion: completion)
    }

    /**
     Clears all markup that has been added to the map, including markers, polylines and ground overlays.
     */
    public func clear() {
        self.underlyingMap.clear()
    }

    // MARK: - Private helpers

    private func moveCamera(update cameraUpdate: MapCameraUpdate, target: CLLocationCoordinate2D,
                                   animated: Bool = true, silently: Bool = false,
                                   completion: (Bool -> Void)? = nil)
    {
        self.cameraFollowsUser = false
        self.performWithoutNotifying = silently
        if self.underlyingMap.isAnimating && animated {
            if self.animationsQueue.count >= kMaximumQueueSize {
                self.animationsQueue.removeLast()
            }

            let element: AnimationQueueElement = (cameraUpdate, target, silently, completion)
            self.animationsQueue.insert(element, atIndex: 0)
            return
        }

        self.queuedCompletion?(false)
        self.queuedCompletion = completion
        self.willMoveMap?(isGesture: false, target: target)
        self.underlyingMap.moveCameraWithUpdate(cameraUpdate, animated: animated)
    }
}

// MARK: - Map Provider Delegate implementation

extension MapView: MapProviderDelegate {

    public func mapProvider(provider: MapSDKProvider, idleAtCameraPosition position: CLLocationCoordinate2D) {
        // We don't want to notify tiny movements, while we are following the user movements as this
        // can be fired very often.
        let didMoveEnough = self.observedCenter.center.distanceTo(position) > kMinimumMovementThreshold
        if didMoveEnough || !self.cameraFollowsUser {
            self.observedCenter.center = position
        }

        self.observedCenter.zoom = self.zoom
        self.performWithoutNotifying = false

        self.queuedCompletion?(true)
        self.queuedCompletion = nil

        if self.animationsQueue.count > 0 {
            let (camera, target, silent, completion) = self.animationsQueue.removeLast()
            return self.moveCamera(update: camera, target: target, silently: silent, completion: completion)
        }

        // Fire it asynchronously so the closure is executed after listeners have heard about this change
        dispatch_async(dispatch_get_main_queue()) { self.highlightedMarker?.select() }
    }

    public func mapProvider(provider: MapSDKProvider, willMoveWithGesture gesture: Bool) {
        if gesture {
            self.willMoveMap?(isGesture: gesture, target: nil)
            self.cameraFollowsUser = false
        }
    }

    public func mapProvider(provider: MapSDKProvider,
                            didChangeCameraPosition position: CLLocationCoordinate2D)
    {
        self.cameraPositionChange.notify(position, previousModel: position)
    }

    public func mapProvider(provider: MapSDKProvider, didTapInfoWindowOfMarker marker: MapMarker) {
        marker.onTooltipTap?(marker)
    }

    public func mapProvider(provider: MapSDKProvider, markerInfoWindow marker: MapMarker) -> UIView? {
        return marker.tooltipView
    }

    public func mapProvider(provider: MapSDKProvider, didTapMarker marker: MapMarker) -> Bool {
        return marker.onTap?(marker) == true
    }
}