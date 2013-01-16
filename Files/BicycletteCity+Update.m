//
//  BicycletteCity+Update.m
//  Bicyclette
//
//  Created by Nicolas on 12/01/13.
//  Copyright (c) 2013 Nicolas Bouilleaud. All rights reserved.
//

#import "BicycletteCity+Update.h"
#import "NSObject+KVCMapping.h"
#import "CollectionsAdditions.h"
#import "NSError+MultipleErrorsCombined.h"
#import "_StationParse.h"

@implementation BicycletteCity (Update)

#pragma mark Data Updates

- (void) update
{
    if(self.updater==nil)
    {
        self.updater = [[DataUpdater alloc] initWithURLStrings:[self updateURLStrings] delegate:self];
        [[NSNotificationQueue defaultQueue] enqueueNotification:[NSNotification notificationWithName:BicycletteCityNotifications.updateBegan object:self]
                                                   postingStyle:NSPostASAP];
    }
}

- (void) updater:(DataUpdater *)updater didFailWithError:(NSError *)error
{
    [[NSNotificationCenter defaultCenter] postNotificationName:BicycletteCityNotifications.updateFailed object:self userInfo:@{BicycletteCityNotifications.keys.failureError : error}];
    self.updater = nil;
}

- (void) updaterDidFinishWithNoNewData:(DataUpdater *)updater
{
    [[NSNotificationCenter defaultCenter] postNotificationName:BicycletteCityNotifications.updateSucceeded object:self userInfo:@{BicycletteCityNotifications.keys.dataChanged : @(NO)}];
    self.updater = nil;
}

- (void) updater:(DataUpdater*)updater finishedWithNewDataChunks:(NSDictionary*)datas
{
    [[NSNotificationCenter defaultCenter] postNotificationName:BicycletteCityNotifications.updateGotNewData object:self];
    
    __block NSError * validationErrors;
    [self performUpdates:^(NSManagedObjectContext *updateContext) {
        // Get Old Stations Names
        NSError * requestError = nil;
        
        NSFetchRequest * oldStationsRequest = [NSFetchRequest fetchRequestWithEntityName:[Station entityName]];
        NSMutableArray* oldStations =  [[updateContext executeFetchRequest:oldStationsRequest error:&requestError] mutableCopy];
        
        _parsing_context = updateContext;
        _parsing_oldStations = oldStations;
        _parsing_regionsByNumber = [NSMutableDictionary new];
        
        // Parsing
        for (NSString * urlString in datas) {
            _parsing_urlString = urlString;
            [self parseData:datas[urlString]];
            _parsing_urlString = nil;
        }
        _parsing_context = nil;
        _parsing_oldStations = nil;
        _parsing_regionsByNumber = nil;
        
        // Post processing :
        // Validate all stations (and delete invalid) before computing coordinates
        NSFetchRequest * allRegionsRequest = [NSFetchRequest fetchRequestWithEntityName:[Region entityName]];
        NSArray * regions = [updateContext executeFetchRequest:allRegionsRequest error:&requestError];
        for (Region *r in regions) {
            for (Station *s in [r.stations copy]) {
                if(![s validateForInsert:&validationErrors])
                {
                    s.region = nil;
                    [updateContext deleteObject:s];
                }
            }
            [r setupCoordinates];
        }
        
        // Delete Old Stations
        for (Station * oldStation in oldStations) {
            if([[NSUserDefaults standardUserDefaults] boolForKey:@"BicycletteLogParsingDetails"])
                NSLog(@"Note : old station deleted after update : %@", oldStation);
            [updateContext deleteObject:oldStation];
        }
        
    } saveCompletion:^(NSNotification *contextDidSaveNotification) {
        NSMutableDictionary * userInfo = [@{BicycletteCityNotifications.keys.dataChanged : @(YES)} mutableCopy];
        if (validationErrors)
            userInfo[BicycletteCityNotifications.keys.saveErrors] = [validationErrors underlyingErrors];
        [[NSNotificationCenter defaultCenter] postNotificationName:BicycletteCityNotifications.updateSucceeded object:self
                                                          userInfo:userInfo];
    }];
    self.updater = nil;
}

- (NSString*) stationNumberFromStationValues:(NSDictionary*)values
{
    NSString * keyForNumber = [[self KVCMapping] allKeysForObject:StationAttributes.number][0]; // There *must* be a key mapping to "number" in the KVCMapping dictionary.
    return values[keyForNumber];
}

- (void) setStation:(Station*)station attributes:(NSDictionary*)stationAttributes
{
    BOOL logParsingDetails = [[NSUserDefaults standardUserDefaults] boolForKey:@"BicycletteLogParsingDetails"];
    
    //
    // Set Values
    [station setValuesForKeysWithDictionary:stationAttributes withMappingDictionary:[self KVCMapping]]; // Yay!
    
    //
    // Set patches
    NSDictionary * patchs = [self patches][station.number];
    BOOL hasDataPatches = patchs && ![[[patchs allKeys] arrayByRemovingObjectsInArray:[[self KVCMapping] allKeys]] isEqualToArray:[patchs allKeys]];
    if(hasDataPatches)
    {
        if(logParsingDetails)
            NSLog(@"Note : Used hardcoded fixes %@. Fixes : %@.",stationAttributes, patchs);
        [station setValuesForKeysWithDictionary:patchs withMappingDictionary:[self KVCMapping]]; // Yay! again
    }
    
    //
    // Build missing status, if needed
    NSArray * keysForStatusAvailable = [[self KVCMapping] allKeysForObject:StationAttributes.status_available];
    NSAssert([keysForStatusAvailable count]==1, nil);
    if([[stationAttributes allKeys] containsObject:keysForStatusAvailable[0]])
    {
        if([[[self KVCMapping] allKeysForObject:StationAttributes.status_total] count]==0)
        {
            // "Total" is not in data
            station.status_totalValue = station.status_freeValue + station.status_availableValue;
        }
        else if ([[[self KVCMapping] allKeysForObject:StationAttributes.status_free] count]==0)
        {
            // "Free" is not in data
            station.status_freeValue = station.status_totalValue - station.status_availableValue;
        }
        
        // Set Date to now
        station.status_date = [NSDate date];
    }
}

- (void) insertStationWithAttributes:(NSDictionary*)stationAttributes
{
    NSString * stationNumber = [self stationNumberFromStationValues:stationAttributes];
    
    BOOL logParsingDetails = [[NSUserDefaults standardUserDefaults] boolForKey:@"BicycletteLogParsingDetails"];
    
    //
    // Find Existing Station
    Station * station = [_parsing_oldStations firstObjectWithValue:stationNumber forKeyPath:StationAttributes.number];
    if(station)
    {
        // found existing
        [_parsing_oldStations removeObject:station];
    }
    else
    {
        if(_parsing_oldStations.count && [[NSUserDefaults standardUserDefaults] boolForKey:@"BicycletteLogParsingDetails"])
            NSLog(@"Note : new station found after update : %@", stationAttributes);
        station = [Station insertInManagedObjectContext:_parsing_context];
    }
    
    // Do it !
    [self setStation:station attributes:stationAttributes];
    
    //
    // Set Region
    RegionInfo * regionInfo;
    if([self hasRegions])
    {
        NSDictionary * patchs = [self patches][station.number];
        regionInfo = [self regionInfoFromStation:station values:stationAttributes patchs:patchs requestURL:_parsing_urlString];
        if(nil==regionInfo)
        {
            if(logParsingDetails)
                NSLog(@"Invalid data : %@",stationAttributes);
            [_parsing_context deleteObject:station];
            return;
        }
    }
    else
    {
        regionInfo = [RegionInfo new];
        regionInfo.number = @"anonymousregion";
        regionInfo.name = @"anonymousregion";
    }
    
    Region * region = _parsing_regionsByNumber[regionInfo.number];
    if(nil==region)
    {
        region = [[Region fetchRegionWithNumber:_parsing_context number:regionInfo.number] lastObject];
        if(region==nil)
        {
            region = [Region insertInManagedObjectContext:_parsing_context];
            region.number = regionInfo.number;
            region.name = regionInfo.number;
        }
        _parsing_regionsByNumber[regionInfo.number] = region;
    }
    station.region = region;
}

+ (BOOL) canUpdateIndividualStations
{
    return [self instancesRespondToSelector:@selector(stationStatusParsingClass)];
}

@end

/****************************************************************************/
#pragma mark -

@implementation RegionInfo
+ (instancetype) infoWithName:(NSString*)name_ number:(NSString*)number_
{
    RegionInfo * info = [self new];
    info.name = name_;
    info.number = number_;
    return info;
}
@end