//
//  Velib.h
//  Bicyclette
//
//  Created by Nicolas on 09/10/10.
//  Copyright 2010 Nicolas Bouilleaud. All rights reserved.
//

#import "CoreDataManager.h"

#import <MapKit/MapKit.h>

#define kVelibStationsListURL		@"http://www.velib.paris.fr/service/carto"
#define kVelibStationsStatusURL		@"http://www.velib.paris.fr/service/stationdetails/"

/****************************************************************************/
#pragma mark -

@class Station;
@class DataUpdater;

@interface VelibModel : CoreDataManager

@property (nonatomic, retain, readonly) DataUpdater * updater;
@property (readonly) BOOL updatingXML;

@property (readonly, nonatomic) MKCoordinateRegion coordinateRegion;
@end
