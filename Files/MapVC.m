//
//  MapVC.m
//  Bicyclette
//
//  Created by Nicolas on 04/12/10.
//  Copyright 2010 Nicolas Bouilleaud. All rights reserved.
//

#import "MapVC.h"
#import "BicycletteApplicationDelegate.h"
#import "VelibModel.h"
#import "Station.h"
#import "Region.h"
#import "NSArrayAdditions.h"
#import "RegionAnnotationView.h"
#import "StationAnnotationView.h"
#import "DrawingCache.h"
#import "Radar.h"
#import "RadarAnnotationView.h"
#import "RadarUpdateQueue.h"

typedef enum {
	MapModeNone = 0,
	MapModeRegions,
	MapModeStations
}  MapMode;

@interface MapVC() <MKMapViewDelegate>
// UI
@property MKMapView * mapView;
@property RadarAnnotationView * screenCenterRadarView;
@property MKUserTrackingBarButtonItem * userTrackingButton;
@property UISegmentedControl * displayControl;

// Data
@property MKCoordinateRegion referenceRegion;
@property (nonatomic) MapMode mode;
@property (nonatomic) MapDisplay display;

// Radar creation
@property (nonatomic) Radar * droppedRadar;
@end


/****************************************************************************/
#pragma mark -

@implementation MapVC 
{
    DrawingCache * _drawingCache;
}

- (void) awakeFromNib
{
    [super awakeFromNib];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(modelUpdated:)
                                                 name:VelibModelNotifications.updateSucceeded object:nil];
    
    
    self.userTrackingButton = [[MKUserTrackingBarButtonItem alloc] initWithMapView:nil];
    
    _displayControl = [[UISegmentedControl alloc] initWithItems:@[ NSLocalizedString(@"BIKES", nil), NSLocalizedString(@"PARKING", nil) ]];
    _displayControl.segmentedControlStyle = UISegmentedControlStyleBar;
    [_displayControl addTarget:self action:@selector(switchDisplay:) forControlEvents:UIControlEventValueChanged];
    _displayControl.selectedSegmentIndex = self.display;
        
    self.toolbarItems = @[self.userTrackingButton,
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
    [[UIBarButtonItem alloc] initWithCustomView:self.displayControl],
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
    
    _drawingCache = [DrawingCache new];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

/****************************************************************************/
#pragma mark Loading

- (BOOL) canBecomeFirstResponder
{
    return YES;
}

- (void) loadView
{
    self.mapView = [[MKMapView alloc]initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    self.view = self.mapView;
    self.mapView.showsUserLocation = YES;
    self.mapView.zoomEnabled = YES;
    self.mapView.scrollEnabled = YES;
    self.mapView.delegate = self;
    
    self.screenCenterRadarView = [[RadarAnnotationView alloc] initWithRadar:self.model.screenCenterRadar];
    self.screenCenterRadarView.center = self.mapView.center;
    [self.mapView addSubview:self.screenCenterRadarView];

    UIGestureRecognizer * longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(addRadar:)];
    [self.mapView addGestureRecognizer:longPressRecognizer];
    
    self.userTrackingButton.mapView = self.mapView;

    [self reloadData];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:@"RadarDistance" options:0 context:(__bridge void *)([MapVC class])];
}

- (void) reloadData
{
    MKCoordinateRegion region = [self.mapView regionThatFits:self.model.regionContainingData];
    region.span.latitudeDelta /= 2;
    region.span.longitudeDelta /= 2;
    self.referenceRegion = region;

	self.mapView.region = self.referenceRegion;

    [self addAndRemoveMapAnnotations];
}

/****************************************************************************/
#pragma mark MapView Delegate

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated
{
	CLLocationDegrees modelSpan = self.referenceRegion.span.latitudeDelta;
	if(self.mapView.region.span.latitudeDelta>modelSpan/10.0f)
		self.mode = MapModeRegions;
	else
		self.mode = MapModeStations;

    self.displayControl.enabled = (self.mode==MapModeStations);
    
    [self addAndRemoveMapAnnotations];
    [self updateRadarSizes];

    self.model.screenCenterRadar.coordinate = self.mapView.centerCoordinate;
    self.model.updaterQueue.referenceLocation = [[CLLocation alloc] initWithLatitude:self.mapView.centerCoordinate.latitude longitude:self.mapView.centerCoordinate.longitude];
}


- (MKAnnotationView *)mapView:(MKMapView *)mapView_ viewForAnnotation:(id <MKAnnotation>)annotation
{
	if(annotation == self.mapView.userLocation)
		return nil;
	else if([annotation isKindOfClass:[Region class]])
	{
		RegionAnnotationView * regionAV = (RegionAnnotationView*)[self.mapView dequeueReusableAnnotationViewWithIdentifier:[RegionAnnotationView reuseIdentifier]];
		if(nil==regionAV)
			regionAV = [[RegionAnnotationView alloc] initWithRegion:annotation drawingCache:_drawingCache];

        return regionAV;
	}
	else if([annotation isKindOfClass:[Station class]])
	{
		StationAnnotationView * stationAV = (StationAnnotationView*)[self.mapView dequeueReusableAnnotationViewWithIdentifier:[StationAnnotationView reuseIdentifier]];
		if(nil==stationAV)
			stationAV = [[StationAnnotationView alloc] initWithStation:(Station*)annotation drawingCache:_drawingCache];

        stationAV.display = self.display;
		return stationAV;
	}
    else if([annotation isKindOfClass:[Radar class]])
    {
        RadarAnnotationView * radarAV = (RadarAnnotationView*)[self.mapView dequeueReusableAnnotationViewWithIdentifier:[RadarAnnotationView reuseIdentifier]];
		if(nil==radarAV)
			radarAV = [[RadarAnnotationView alloc] initWithRadar:(Radar*)annotation];
        
        CGSize radarSize = [self.mapView convertRegion:((Radar*)annotation).radarRegion toRectToView:self.mapView].size;
        radarAV.bounds = (CGRect){CGPointZero, radarSize};

        return radarAV;
    }
	return nil;
}

- (void)mapView:(MKMapView *)mapView didSelectAnnotationView:(MKAnnotationView *)view
{
	if([view.annotation isKindOfClass:[Region class]])
		[self zoomInRegion:(Region*)view.annotation];
    else if([view.annotation isKindOfClass:[Station class]])
        [self refreshStation:(Station*)view.annotation]; 
}

- (void)mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view didChangeDragState:(MKAnnotationViewDragState)newState
fromOldState:(MKAnnotationViewDragState)oldState
{
    if([view.annotation isKindOfClass:[Radar class]])
    {
        [self.mapView selectAnnotation:view.annotation animated:YES];
        if(newState==MKAnnotationViewDragStateCanceling)
            [self showRadarMenu:(Radar*)view.annotation];
    }

}

- (void)mapView:(MKMapView *)mapView didUpdateUserLocation:(MKUserLocation *)userLocation
{
    [self.model userLocationRadar].coordinate = userLocation.coordinate;
}

- (void) addAndRemoveMapAnnotations
{
    NSArray * oldAnnotations = self.mapView.annotations;
    oldAnnotations = [oldAnnotations arrayByRemovingObjectsInArray:@[ self.mapView.userLocation ]];
    NSArray * newAnnotations;
    

    if (self.mode == MapModeRegions)
    {
        NSFetchRequest * regionsRequest = [NSFetchRequest new];
        regionsRequest.entity = [Region entityInManagedObjectContext:self.model.moc];
        newAnnotations = [self.model.moc executeFetchRequest:regionsRequest error:NULL];
    }
    else
    {
        NSFetchRequest * stationsRequest = [NSFetchRequest new];
		[stationsRequest setEntity:[Station entityInManagedObjectContext:self.model.moc]];
        MKCoordinateRegion mapRegion = self.mapView.region;
		stationsRequest.predicate = [NSPredicate predicateWithFormat:@"latitude>%f AND latitude<%f AND longitude>%f AND longitude<%f",
							 mapRegion.center.latitude - mapRegion.span.latitudeDelta/2,
                             mapRegion.center.latitude + mapRegion.span.latitudeDelta/2,
                             mapRegion.center.longitude - mapRegion.span.longitudeDelta/2,
                             mapRegion.center.longitude + mapRegion.span.longitudeDelta/2];
        newAnnotations = [self.model.moc executeFetchRequest:stationsRequest error:NULL];

        NSFetchRequest * radarsRequest = [NSFetchRequest new];
		[radarsRequest setEntity:[Radar entityInManagedObjectContext:self.model.moc]];
        NSMutableArray * allRadars = [[self.model.moc executeFetchRequest:radarsRequest error:NULL] mutableCopy];
        // do not add an annotation for screenCenterRadar, it's handled separately.
        [allRadars removeObject:self.model.screenCenterRadar];
        newAnnotations = [newAnnotations arrayByAddingObjectsFromArray:allRadars];
    }

    NSArray * annotationsToRemove = [oldAnnotations arrayByRemovingObjectsInArray:newAnnotations];
    NSArray * annotationsToAdd = [newAnnotations arrayByRemovingObjectsInArray:oldAnnotations];
    
    [self.mapView removeAnnotations:annotationsToRemove];
    [self.mapView addAnnotations:annotationsToAdd];
}

- (void) updateRadarSizes
{
    for (Radar * radar in self.mapView.annotations)
    {
        if([radar isKindOfClass:[Radar class]])
        {
            CGSize radarSize = [self.mapView convertRegion:radar.radarRegion toRectToView:self.mapView].size;
            [self.mapView viewForAnnotation:radar].bounds = (CGRect){CGPointZero, radarSize};
        }
    }
    CGSize radarSize = [self.mapView convertRegion:self.model.screenCenterRadar.radarRegion toRectToView:self.mapView].size;
    self.screenCenterRadarView.bounds = (CGRect){CGPointZero, radarSize};
}

/****************************************************************************/
#pragma mark Actions

- (void) addRadar:(UILongPressGestureRecognizer*)longPressRecognizer
{
    switch (longPressRecognizer.state)
    {
        case UIGestureRecognizerStatePossible:
            break;
            
        case UIGestureRecognizerStateBegan:
            self.droppedRadar = [Radar insertInManagedObjectContext:self.model.moc];
            [self.mapView addAnnotation:self.droppedRadar];
            self.droppedRadar.coordinate = [self.mapView convertPoint:[longPressRecognizer locationInView:self.mapView]
                                                 toCoordinateFromView:self.mapView];
            [self performSelector:@selector(selectDroppedRadar) withObject:nil afterDelay:.2]; // Strangely, the mapview does not return the annotation view before a delay
            break;
        case UIGestureRecognizerStateChanged:
            self.droppedRadar.coordinate = [self.mapView convertPoint:[longPressRecognizer locationInView:self.mapView]
                                                 toCoordinateFromView:self.mapView];
            break;
        case UIGestureRecognizerStateEnded:
            [[self.mapView viewForAnnotation:self.droppedRadar] setDragState:MKAnnotationViewDragStateEnding animated:YES];
            break;
            
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self.mapView removeAnnotation:self.droppedRadar];
            [self.model.moc deleteObject:self.droppedRadar];
            self.droppedRadar = nil;
            break;
    }
}

- (void) selectDroppedRadar
{
    [self.mapView selectAnnotation:self.droppedRadar animated:YES];
    [[self.mapView viewForAnnotation:self.droppedRadar] setDragState:MKAnnotationViewDragStateStarting animated:YES];
}

- (void) refreshStation:(Station*)station
{
    [station refresh];
}

- (void) zoomInRegion:(Region*)region
{
    MKCoordinateRegion cregion = [self.mapView regionThatFits:region.coordinateRegion];
    cregion = MKCoordinateRegionMakeWithDistance(cregion.center, 1000, 1000);
	[self.mapView setRegion:cregion animated:YES];
}

- (void) showRadarMenu:(Radar*)radar
{
    [self becomeFirstResponder];
    UIMenuController * menu = [UIMenuController sharedMenuController];
    
    CGPoint point = [self.mapView convertCoordinate:radar.coordinate toPointToView:self.mapView];
    [menu setTargetRect:(CGRect){point,CGSizeZero} inView:self.mapView];
    [menu setMenuVisible:YES animated:YES];
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    BOOL res = [super canPerformAction:action withSender:sender];
    return res;
}

- (void) delete:(id)sender // From UIMenuController
{
    for (Radar * radar in self.mapView.selectedAnnotations)
    {
        if([radar isKindOfClass:[Radar class]])
        {
            [self.mapView removeAnnotation:radar];
            [self.model.moc deleteObject:radar];
        }
    }
}

- (void) switchDisplay:(UISegmentedControl*)sender
{
    self.display = sender.selectedSegmentIndex;

    if(self.mode==MapModeStations)
    {
        for (id<MKAnnotation> annotation in self.mapView.annotations) {
            StationAnnotationView * stationAV = (StationAnnotationView*)[self.mapView viewForAnnotation:annotation];
            if([stationAV isKindOfClass:[StationAnnotationView class]])
                stationAV.display = self.display;
        }
    }
}

/****************************************************************************/
#pragma mark -

- (void) setAnnotationsHidden:(BOOL)hidden
{
    for (id annotation in self.mapView.annotations) 
        [self.mapView viewForAnnotation:annotation].hidden = hidden;
}

/****************************************************************************/
#pragma mark -

- (void) modelUpdated:(NSNotification*) note
{
    if([note.userInfo[VelibModelNotifications.keys.dataChanged] boolValue])
        [self reloadData];
}

/****************************************************************************/
#pragma mark -

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == (__bridge void *)([MapVC class])) {
        if([keyPath isEqualToString:@"RadarDistance"])
            [self updateRadarSizes];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end
