//
//  WMFImageGalleryViewController.m
//  Wikipedia
//
//  Created by Brian Gerstle on 1/16/15.
//  Copyright (c) 2015 Wikimedia Foundation. All rights reserved.
//

#import "WMFImageGalleryViewController_Subclass.h"
#import "WMFBaseImageGalleryViewController_Subclass.h"
#import "Wikipedia-Swift.h"

#import "AnyPromise+WMFExtensions.h"

// Utils
#import <BlocksKit/BlocksKit.h>
#import "WikipediaAppUtils.h"
#import "SessionSingleton.h"
#import "MWNetworkActivityIndicatorManager.h"
#import "NSArray+WMFLayoutDirectionUtilities.h"
#import "UIViewController+WMFOpenExternalUrl.h"

// View
#import <Masonry/Masonry.h>
#import "WMFImageGalleryCollectionViewCell.h"
#import "WMFImageGalleryDetailOverlayView.h"
#import "UIFont+WMFStyle.h"
#import "UIButton+WMFButton.h"
#import "UICollectionViewFlowLayout+NSCopying.h"
#import "UICollectionViewFlowLayout+WMFItemSizeThatFits.h"
#import "WMFCollectionViewPageLayout.h"
#import "UIViewController+Alert.h"
#import "UICollectionViewLayout+AttributeUtils.h"
#import "UILabel+WMFStyling.h"
#import "UIButton+FrameUtils.h"
#import "UIView+WMFFrameUtils.h"
#import "WMFGradientView.h"
#import "UICollectionView+WMFExtensions.h"

// Model
#import "MWKImage.h"
#import "MWKLicense+ToGlyph.h"
#import "MWKImageInfo+MWKImageComparison.h"
#import "MWKArticle.h"

// Data Source
#import "WMFModalImageGalleryDataSource.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^ WMFGalleryCellEnumerator)(WMFImageGalleryCollectionViewCell* cell, NSIndexPath* indexPath);

static double const WMFImageGalleryTopGradientHeight = 150.0;

static NSString* const WMFImageGalleryCollectionViewCellReuseId = @"WMFImageGalleryCollectionViewCellReuseId";

@implementation WMFImageGalleryViewController

+ (UICollectionViewFlowLayout*)wmf_defaultGalleryLayout {
    UICollectionViewFlowLayout* defaultLayout = [[WMFCollectionViewPageLayout alloc] init];
    defaultLayout.sectionInset            = UIEdgeInsetsZero;
    defaultLayout.minimumInteritemSpacing = 0.f;
    defaultLayout.minimumLineSpacing      = 0.f;
    defaultLayout.scrollDirection         = UICollectionViewScrollDirectionHorizontal;
    return defaultLayout;
}

- (instancetype)init {
    self = [super initWithCollectionViewLayout:[[self class] wmf_defaultGalleryLayout]];
    if (self) {
        self.chromeHidden         = NO;
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

#pragma mark - Accessors

- (void)setDataSource:(SSBaseDataSource<WMFImageGalleryDataSource>*)dataSource {
    NSParameterAssert([dataSource conformsToProtocol:@protocol(WMFModalImageGalleryDataSource)]);
    [super setDataSource:dataSource];
    self.dataSource.cellClass = [WMFImageGalleryCollectionViewCell class];
    @weakify(self);
    self.dataSource.cellConfigureBlock = ^(WMFImageGalleryCollectionViewCell* cell,
                                           id __unused obj,
                                           UICollectionView* _,
                                           NSIndexPath* indexPath) {
        @strongify(self);
        [self updateCell:cell atIndexPath:indexPath];
    };
}

- (id<WMFModalImageGalleryDataSource>)modalGalleryDataSource {
    return (id<WMFModalImageGalleryDataSource>)self.dataSource;
}

- (UICollectionViewFlowLayout*)collectionViewFlowLayout {
    UICollectionViewFlowLayout* flowLayout = (UICollectionViewFlowLayout*)self.collectionView.collectionViewLayout;
    if ([flowLayout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        return flowLayout;
    } else if (flowLayout) {
        [NSException raise:@"InvalidCollectionViewLayoutSubclass"
                    format:@"%@ expected %@ to be a subclass of %@",
         self, flowLayout, NSStringFromClass([UICollectionViewFlowLayout class])];
    }
    return nil;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // fetch after appearing so we don't do work while the animation is rendering
    [[self modalGalleryDataSource] prefetchDataNearIndexPath:[NSIndexPath indexPathForItem:self.currentPage inSection:0]];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIActivityIndicatorView* loadingIndicator =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    loadingIndicator.hidesWhenStopped = YES;
    [loadingIndicator stopAnimating];
    [self.view addSubview:loadingIndicator];
    [loadingIndicator mas_makeConstraints:^(MASConstraintMaker* make) {
        make.center.equalTo(self.view);
    }];
    self.loadingIndicator = loadingIndicator;

    self.collectionView.showsHorizontalScrollIndicator = NO;
    self.collectionView.showsVerticalScrollIndicator   = NO;

    WMFGradientView* topGradientView = [WMFGradientView new];
    topGradientView.userInteractionEnabled = NO;
    [topGradientView.gradientLayer setLocations:@[@0, @1]];
    [topGradientView.gradientLayer setColors:@[(id)[UIColor colorWithWhite:0.0 alpha:1.0].CGColor,
                                               (id)[UIColor clearColor].CGColor]];
    // default start/end points, to be adjusted w/ image size
    [topGradientView.gradientLayer setStartPoint:CGPointMake(0.5, 0.0)];
    [topGradientView.gradientLayer setEndPoint:CGPointMake(0.5, 1.0)];
    [self.view addSubview:topGradientView];
    _topGradientView = topGradientView;

    [self.topGradientView mas_makeConstraints:^(MASConstraintMaker* make) {
        make.top.equalTo(self.view.mas_top);
        make.leading.equalTo(self.view.mas_leading);
        make.trailing.equalTo(self.view.mas_trailing);
        make.height.mas_equalTo(WMFImageGalleryTopGradientHeight);
    }];

    @weakify(self)
    UIButton * closeButton = [UIButton wmf_buttonType:WMFButtonTypeClose handler:^(id sender){
        @strongify(self)
        [self closeButtonTapped : sender];
    }];
    closeButton.tintColor = [UIColor whiteColor];
    [self.view addSubview:closeButton];
    _closeButton = closeButton;

    [self.closeButton mas_makeConstraints:^(MASConstraintMaker* make) {
        make.width.and.height.mas_equalTo(60.f);
        make.leading.equalTo(self.view.mas_leading);
        make.top.equalTo(self.view.mas_top);
    }];

    UITapGestureRecognizer* chromeTapGestureRecognizer =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didTapView:)];

    // make sure taps don't interfere w/ other gestures
    chromeTapGestureRecognizer.delaysTouchesBegan   = NO;
    chromeTapGestureRecognizer.delaysTouchesEnded   = NO;
    chromeTapGestureRecognizer.cancelsTouchesInView = NO;
    chromeTapGestureRecognizer.delegate             = self;

    // NOTE(bgerstle): recognizer must be added to collection view so as to not disrupt interactions w/ overlay UI
    [self.collectionView addGestureRecognizer:chromeTapGestureRecognizer];
    _chromeTapGestureRecognizer = chromeTapGestureRecognizer;

    self.collectionView.backgroundColor = [UIColor blackColor];
    [self.collectionView registerClass:[WMFImageGalleryCollectionViewCell class]
            forCellWithReuseIdentifier:[WMFImageGalleryCollectionViewCell identifier]];

    [self applyChromeHidden:NO];
}

#pragma mark - Chrome

- (void)didTapView:(UITapGestureRecognizer*)sender {
    [self toggleChromeHidden:YES];
}

- (void)toggleChromeHidden:(BOOL)animated {
    [self setChromeHidden:![self isChromeHidden] animated:animated];
}

- (void)setChromeHidden:(BOOL)hidden {
    [self setChromeHidden:hidden animated:NO];
}

- (void)setChromeHidden:(BOOL)hidden animated:(BOOL)animated {
    if (_chromeHidden == hidden) {
        return;
    }
    _chromeHidden = hidden;
    [self applyChromeHidden:animated];
}

- (void)applyChromeHidden:(BOOL)animated {
    if (![self isViewLoaded]) {
        return;
    }
    dispatch_block_t animations = ^{
        self.topGradientView.hidden = [self isChromeHidden];
        self.closeButton.hidden     = [self isChromeHidden];
        for (NSIndexPath* indexPath in self.collectionView.indexPathsForVisibleItems) {
            [self updateDetailVisibilityForCellAtIndexPath:indexPath];
        }
    };

    if (animated) {
        [UIView animateWithDuration:[CATransaction animationDuration]
                              delay:0
                            options:UIViewAnimationOptionTransitionCrossDissolve
                         animations:animations
                         completion:nil];
    } else {
        animations();
    }
}

#pragma mark - Dismissal

- (void)closeButtonTapped:(id)sender {
    if ([self.delegate respondsToSelector:@selector(willDismissGalleryController:)]) {
        [self.delegate willDismissGalleryController:self];
    }
    [self dismissViewControllerAnimated:YES completion:^{
        if ([self.delegate respondsToSelector:@selector(didDismissGalleryController:)]) {
            [self.delegate didDismissGalleryController:self];
        }
    }];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)                             gestureRecognizer:(UIGestureRecognizer*)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)otherGestureRecognizer {
    return gestureRecognizer != self.chromeTapGestureRecognizer;
}

- (BOOL)                  gestureRecognizer:(UIGestureRecognizer*)gestureRecognizer
    shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer*)otherGestureRecognizer {
    return gestureRecognizer == self.chromeTapGestureRecognizer;
}

#pragma mark - CollectionView

#pragma mark Delegate

- (void)collectionView:(UICollectionView*)collectionView
       willDisplayCell:(UICollectionViewCell*)cell
    forItemAtIndexPath:(NSIndexPath*)indexPath {
    /*
       since we have to wait until the cells are laid out before applying visibleImageIndex, this method can be
       called before currentPage has been applied.  as a result, we check the flag here to ensure our first fetch
       is for the current visible image. otherwise, we could fetch the first image in the gallery, apply visibleImageIndex,
       then fetch the visible image.
     */
    if (self.didApplyCurrentPage) {
        [[self modalGalleryDataSource] prefetchDataNearIndexPath:indexPath];
    }
}

#pragma mark - Cell Updates

- (void)updateCell:(WMFImageGalleryCollectionViewCell*)cell atIndexPath:(NSIndexPath*)indexPath {
    MWKImageInfo* infoForImage = [[self modalGalleryDataSource] imageInfoAtIndexPath:indexPath];

    [cell startLoadingAfterDelay:0.25];

    [self updateDetailVisibilityForCell:cell withInfo:infoForImage];

    if (infoForImage) {
        cell.detailOverlayView.imageDescription =
            [infoForImage.imageDescription stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        NSString* ownerOrFallback = infoForImage.owner ?
                                    [infoForImage.owner stringByTrimmingCharactersInSet : [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                    : MWLocalizedString(@"image-gallery-unknown-owner", nil);

        [cell.detailOverlayView setLicense:infoForImage.license owner:ownerOrFallback];

        cell.detailOverlayView.ownerTapCallback = ^{
            [self wmf_openExternalUrl:infoForImage.license.URL];
        };
    }

    [self updateImageForCell:cell
                 atIndexPath:indexPath
         placeholderImageURL:[self.dataSource imageURLAtIndexPath:indexPath]
                        info:infoForImage];
}

#pragma mark - Image Details

- (void)updateDetailVisibilityForCellAtIndexPath:(NSIndexPath*)indexPath {
    WMFImageGalleryCollectionViewCell* cell =
        (WMFImageGalleryCollectionViewCell*)[self.collectionView cellForItemAtIndexPath:indexPath];
    [self updateDetailVisibilityForCell:cell atIndexPath:indexPath];
}

- (void)updateDetailVisibilityForCell:(WMFImageGalleryCollectionViewCell*)cell
                          atIndexPath:(NSIndexPath*)indexPath {
    [self updateDetailVisibilityForCell:cell withInfo:[[self modalGalleryDataSource] imageInfoAtIndexPath:indexPath]];
}

- (void)updateDetailVisibilityForCell:(WMFImageGalleryCollectionViewCell*)cell
                             withInfo:(MWKImageInfo*)info {
    BOOL const shouldHideDetails = [self isChromeHidden]
                                   || (!info.imageDescription && !info.owner && !info.license);
    cell.detailOverlayView.alpha = shouldHideDetails ? 0.0 : 1.0;
}

#pragma mark - Image Handling

- (void)updateImageAtIndexPath:(NSIndexPath*)indexPath {
    NSParameterAssert(indexPath);
    WMFImageGalleryCollectionViewCell* cell =
        (WMFImageGalleryCollectionViewCell*)[self.collectionView cellForItemAtIndexPath:indexPath];
    if (cell) {
        [self updateImageForCell:cell
                     atIndexPath:indexPath
             placeholderImageURL:[self.dataSource imageURLAtIndexPath:indexPath]
                            info:[[self modalGalleryDataSource] imageInfoAtIndexPath:indexPath]];
    }
}

- (void)updateImageForCell:(WMFImageGalleryCollectionViewCell*)cell
               atIndexPath:(NSIndexPath*)indexPath
       placeholderImageURL:(NSURL*)placeholderImageURL
                      info:(MWKImageInfo* __nullable)infoForImage {
    NSParameterAssert(cell);
    @weakify(self);
    [[WMFImageController sharedInstance]
     cascadingFetchWithMainURL:infoForImage.imageThumbURL
           cachedPlaceholderURL:placeholderImageURL
                 mainImageBlock:^(WMFImageDownload* download) {
        @strongify(self);
        [self setImage:download.image withInfo:infoForImage forCellAtIndexPath:indexPath];
    }
    cachedPlaceholderImageBlock:^(WMFImageDownload* download) {
        @strongify(self);
        [self setPlaceholderImage:download.image ofInfo:infoForImage forCellAtIndexPath:indexPath];
    }]
    .catch(^(NSError* error) {
        DDLogWarn(@"Failed to load image for cell at %@: %@", indexPath, error);
        @strongify(self);
        [self showAlert:error.localizedDescription type:ALERT_TYPE_TOP duration:-1];
    });
}

- (void)      setImage:(UIImage*)image
              withInfo:(MWKImageInfo*)info
    forCellAtIndexPath:(NSIndexPath*)indexPath {
    DDLogDebug(@"Setting image for info %@ to indexpath %@", info, indexPath);
    WMFImageGalleryCollectionViewCell* cell =
        (WMFImageGalleryCollectionViewCell*)[self.collectionView cellForItemAtIndexPath:indexPath];
    if (!cell) {
        DDLogDebug(@"Not applying download for %@ at %@ since cell is no longer visible.", info, indexPath);
        return;
    }
    cell.image     = image;
    cell.imageSize = info.thumbSize;
    cell.loading   = NO;
}

- (void)setPlaceholderImage:(UIImage* __nullable)image
                     ofInfo:(MWKImageInfo* __nullable)info
         forCellAtIndexPath:(NSIndexPath*)indexPath {
    if (!image) {
        return;
    }
    NSAssert(!info
             || ![[WMFImageController sharedInstance] hasImageWithURL:info.imageThumbURL]
             || (!info && ![[WMFImageController sharedInstance] hasImageWithURL:info.imageThumbURL]),
             @"Breach of contract to never apply variant when desired image is present!");
    DDLogDebug(@"Applying variant of info %@ to indexpath %@", info, indexPath);
    WMFImageGalleryCollectionViewCell* cell =
        (WMFImageGalleryCollectionViewCell*)[self.collectionView cellForItemAtIndexPath:indexPath];
    if (!cell) {
        DDLogDebug(@"Not applying download of variant for %@ at %@ since cell is no longer visible.",
                   info, indexPath);
        return;
    }
    cell.image = image;
    /*
       set the expected image size to the image info's size if we have it, yielding the "ENHANCE" effect when
       the higher-res image is downloaded
     */
    cell.imageSize = info ? info.thumbSize : image.size;
    if (!info) {
        // only stop loading if info is nil, meaning that there's no high-res image coming
        cell.loading = NO;
    }
}

#pragma mark - WMFModalGalleryDataSourceDelegate

- (void)modalGalleryDataSource:(id<WMFModalImageGalleryDataSource>)dataSource didFailWithError:(NSError *)error {
    [self.loadingIndicator stopAnimating];
    [self showAlert:error.localizedDescription type:ALERT_TYPE_TOP duration:-1];
}

- (void)modalGalleryDataSource:(id<WMFModalImageGalleryDataSource>)dataSource updatedItemsAtIndexes:(NSIndexSet *)indexes {
    [self.loadingIndicator stopAnimating];
    [self.collectionView wmf_enumerateVisibleCellsUsingBlock:^(WMFImageGalleryCollectionViewCell* cell,
                                                               NSIndexPath* indexPath,
                                                               BOOL* _) {
        if ([indexes containsIndex:indexPath.item]) {
            [self updateCell:cell atIndexPath:indexPath];
        }
    }];
}

@end

NS_ASSUME_NONNULL_END
