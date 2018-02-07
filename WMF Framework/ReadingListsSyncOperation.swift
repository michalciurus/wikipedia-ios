internal class ReadingListsSyncOperation: ReadingListsOperation {
    override func execute() {
        readingListsController.apiController.getAllReadingLists { (allAPIReadingLists, getAllAPIReadingListsError) in
            if let error = getAllAPIReadingListsError {
                self.finish(with: error)
                return
            }
            DispatchQueue.main.async {
                self.dataStore.performBackgroundCoreDataOperation(onATemporaryContext: { (moc) in
                    if let remoteDefaultReadingList: APIReadingList = allAPIReadingLists.filter({ (list) -> Bool in return list.isDefault }).first {
                        let defaultReadingList = moc.wmf_fetchDefaultReadingList()
                        defaultReadingList?.readingListID = NSNumber(value: remoteDefaultReadingList.id)
                    }
                    
                    let group = WMFTaskGroup()
                    do {
                        let readingListSinceDate = try self.readingListsController.createOrUpdate(remoteReadingLists: allAPIReadingLists, inManagedObjectContext: moc)
                        var remoteEntriesByReadingListID: [Int64: [APIReadingListEntry]] = [:]
                        for remoteReadingList in allAPIReadingLists {
                            group.enter()
                            self.apiController.getAllEntriesForReadingListWithID(readingListID: remoteReadingList.id, completion: { (entries, error) in
                                if error == nil {
                                    remoteEntriesByReadingListID[remoteReadingList.id] = entries
                                }
                                group.leave()
                            })
                        }
                        
                        group.wait()
                        
                        var entrySinceDate = Date.distantPast
                        for (readingListID, remoteReadingListEntries) in remoteEntriesByReadingListID {
                            let listEntrySinceDate = try self.readingListsController.createOrUpdate(remoteReadingListEntries: remoteReadingListEntries, for: readingListID, inManagedObjectContext: moc)
                            if listEntrySinceDate.compare(entrySinceDate) == .orderedDescending {
                                entrySinceDate = listEntrySinceDate
                            }
                        }
                        
                        let sinceDate = readingListSinceDate.compare(entrySinceDate) == .orderedDescending ? readingListSinceDate : entrySinceDate
                        if sinceDate.compare(Date.distantPast) != .orderedSame {
                            let iso8601String = DateFormatter.wmf_iso8601().string(from: sinceDate)
                            moc.wmf_setValue(iso8601String as NSString, forKey: WMFReadingListUpdateKey)
                        }
                        
                        try self.readingListsController.processLocalUpdates(in: moc)
                        
                        guard moc.hasChanges else {
                            return
                        }
                        try moc.save()
                        
                    } catch let error {
                        DDLogError("Error during reading list sync: \(error)")
                    }
                    self.finish()
                })
            }
        }
    }
}
