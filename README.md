JTPDropboxFilesManager
======================

Summary:
A wrapper class for Dropbox's Sync API for iOS that handles asynchronous, atomic CRUD operations with an easy-to-use API. This class is currently used in Jot – Refined Text Editor (www.jot-app.com).

 JTPDropboxFilesManager is a controller class that deals with the fact that, at any given time, there may be multiple DBFile instances that are downloading, uploading or idle. Its purpose is to prevent erroneous overwrites, conflicted copies, and data corruption. This class is intended to be used by multiple classes that range from Dropbox directory controllers to Text Kit model/view classes.
 
 @discussion Typically, a user will open, edit, and close a file, in that order. In such a scenario, managing read/write operations is relatively simple. However, more often than not, the user may do things differently.
 
 @discussion CASE 1: Users may quickly open and close the same file. To prevent erroneous overwrites, conflicted copies, and data corruption, any operation on that file should be serially queued.
 
 @discussion CASE 2: Users may choose to open and close multiple files in quick succession. In this case, operations on different files may run concurrently in the background. However, like 'CASE 1', operations on a single file should always be serially queued.
 
 @discussion Files are indirectly accessed via DBPath. Each file is uniqued by its [DBPath stringValue], which is used as a key in an NSDictionary for accessing files.
 
 @warning Clients must explicity call -close on DBFile instances. You should do this when the file's user interface is closed (i.e. user closes the file's text view). Calls will be enqueued serially, but make sure that you call -close after all other operations on that file have been enqueued.
