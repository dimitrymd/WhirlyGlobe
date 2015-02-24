/*
 *  MapboxMultiSourcetileInfo.m
 *  WhirlyGlobe-MaplyComponent
 *
 *  Created by Steve Gifford on 2/23/15.
 *  Copyright 2011-2015 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "MapboxMultiSourceTileInfo.h"
#import "MapnikStyleSet.h"
#import "MapboxVectorStyleSet.h"
#import <set>
#import <vector>
#import <string>

// Used to encapsulate a single tile source
// Yes, it's C++.  Suffer.
class SingleTileSource
{
public:
    SingleTileSource() : isImage(true), map(nil), ext(@"png"), styleSet(nil), minZoom(0), maxZoom(22) { }
    
    // Whether it's an image or vector source
    bool isImage;
    // Name of map
    NSString *map;
    NSString *ext;
    // Style sheet, if this is vector
    NSObject<MaplyVectorStyleDelegate> *styleSet;
    // Specific tile URLs, if we have them
    NSArray *tileURLs;
    int minZoom,maxZoom;
};

@implementation MapboxMultiSourceTileInfo
{
    MaplyBaseViewController *viewC;
    std::vector<NSString *> baseURLs;
    std::vector<SingleTileSource> sources;
    // Sorted by zoom level
    std::vector<std::vector<int> > sourcesByZoom;
}

- (id)initWithViewC:(MaplyBaseViewController *)inViewC
{
    self = [super init];
    if (!self)
        return nil;
    viewC = inViewC;
    self.minZoom = -1;
    self.maxZoom = -1;
    self.coordSys = [[MaplySphericalMercator alloc] initWebStandard];
    
    baseURLs.push_back(@"http://a.tiles.mapbox.com/v4");
    baseURLs.push_back(@"http://b.tiles.mapbox.com/v4");
    
    return self;
}

- (int)minZoom
{
    // Find the first level with an entry
    for (int ii=0;ii<sourcesByZoom.size();ii++)
        if (!sourcesByZoom[ii].empty())
            return ii;
    
    // If this happens, you haven't filled in any data
    return 0;
}

- (int)maxZoom
{
    return sourcesByZoom.size()-1;
}

- (bool)addImageMap:(NSString *)map minZoom:(int)minZoom maxZoom:(int)maxZoom type:(NSString *)imageType
{
    SingleTileSource source;
    source.isImage = true;
    source.map = map;
    source.minZoom = minZoom;  source.maxZoom = maxZoom;
    source.ext = imageType;
    sources.push_back(source);
    [self addedSource:sources.size()-1];
    
    return true;
}

- (bool)addVectorMap:(NSString *)map style:(NSData *)styleData styleType:(MapnikStyleType)styleType minZoom:(int)minZoom maxZoom:(int)maxZoom
{
    // Parse the style sheet
    NSObject<MaplyVectorStyleDelegate> *styleSet = nil;
    switch (styleType)
    {
        case MapnikXMLStyle:
        {
            MapnikStyleSet *mapnikStyleSet = [[MapnikStyleSet alloc] initForViewC:viewC];
            [mapnikStyleSet loadXmlData:styleData];
            [mapnikStyleSet generateStyles];
            styleSet = mapnikStyleSet;
        }
            break;
        case MapnikMapboxGLStyle:
        {
            MaplyMapboxVectorStyleSet *mapboxStyleSet = [[MaplyMapboxVectorStyleSet alloc] initWithJSON:styleData viewC:viewC];
            styleSet = mapboxStyleSet;
        }
            break;
    }

    SingleTileSource source;
    source.isImage = false;
    source.map = map;
    source.minZoom = minZoom;
    source.maxZoom = maxZoom;
    source.ext = @"vector.pbf";
    source.styleSet = styleSet;
    sources.push_back(source);
    [self addedSource:sources.size()-1];
    
    return true;
}

- (bool)addTileSpec:(NSDictionary *)jsonDict
{
    SingleTileSource source;
    source.isImage = false;
    
    source.tileURLs = jsonDict[@"tiles"];
    if (![source.tileURLs isKindOfClass:[NSArray class]])
        return false;
    NSString *tileURL = source.tileURLs[0];
    if (![tileURL isKindOfClass:[NSString class]])
        return false;
    if ([tileURL containsString:@".png"] || [tileURL containsString:@".jpg"])
        source.isImage = true;
    else if ([tileURL containsString:@".vector.pbf"])
    {
        NSLog(@"Can't handle vector tiles from PBF in MaplyMultiSourceTileInfo");
        return false;
    } else {
        NSLog(@"Don't know what this source is");
        return false;
    }
    
    source.minZoom = [jsonDict[@"minzoom"] intValue];
    source.maxZoom = [jsonDict[@"maxzoom"] intValue];
    sources.push_back(source);
    [self addedSource:sources.size()-1];
    
    return true;
}

- (void)addedSource:(int)which
{
    SingleTileSource &source = sources[which];
    if (source.maxZoom >= sourcesByZoom.size())
        sourcesByZoom.resize(source.maxZoom+1);
    
    for (int zoom = source.minZoom; zoom <= source.maxZoom; zoom++)
    {
        std::vector<int> &inLevel = sourcesByZoom[zoom];
        inLevel.push_back(which);
    }
}

- (void)findParticipatingSources:(std::vector<SingleTileSource *> &)partSources forLevel:(int)level
{
    std::vector<int> &whichIDs = sourcesByZoom[level];
    for (unsigned int ii=0;ii<whichIDs.size();ii++)
    {
        partSources.push_back(&sources[ii]);
    }
}

// Called by the remote tile source to get a URL to fetch
- (NSURLRequest *)requestForTile:(MaplyTileID)tileID
{
    // Figure out the participating sources
    std::vector<SingleTileSource *> partSources;
    [self findParticipatingSources:partSources forLevel:tileID.level];
    
    if (partSources.size() != 1)
    {
        NSLog(@"Can only deal with one source per level right now.");
        return nil;
    }

    // Pick a base URL and flip the y
    int y = ((int)(1<<tileID.level)-tileID.y)-1;
    
    SingleTileSource *source = partSources[0];
    NSString *fullURLStr = nil;
    if (source->tileURLs)
    {
        NSString *tileURL = source->tileURLs[random()%[source->tileURLs count]];
        fullURLStr = [[[tileURL stringByReplacingOccurrencesOfString:@"{z}" withString:[@(tileID.level) stringValue]]
                                 stringByReplacingOccurrencesOfString:@"{x}" withString:[@(tileID.x) stringValue]]
                                stringByReplacingOccurrencesOfString:@"{y}" withString:[@(y) stringValue]];
    } else {
        // Pick a base URL and build the full URL
        NSString *baseURL = baseURLs[tileID.x%baseURLs.size()];
        fullURLStr = [NSString stringWithFormat:@"%@/%@/%d/%d/%d.%@",baseURL,source->map,tileID.level,tileID.x,y,source->ext];
    }
    NSMutableURLRequest *urlReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fullURLStr]];
    if (self.timeOut != 0.0)
        [urlReq setTimeoutInterval:self.timeOut];
    
    return urlReq;
}

@end