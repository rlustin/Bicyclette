#import "_Region.h"
#import <MapKit/MapKit.h>

@interface Region : _Region {}
- (void) setupCoordinates;

@property (readonly, nonatomic) MKCoordinateRegion coordinateRegion;
@end