/*
* MIT Licensed
* http://www.23developer.com/opensource
* http://github.com/23/resumable.js
* Steffen Tiedemann Christensen, steffen@23company.com
*/

(function () {
  "use strict";

  const Resumable = function (opts) {
    if (!(this instanceof Resumable)) {
      return new Resumable(opts);
    }
    this.version = 1.0;
    // SUPPORTED BY BROWSER?
    // Check if these features are support by the browser:
    // - File object type
    // - Blob object type
    // - FileList object type
    // - slicing files
    this.support = (
      (typeof (File) !== 'undefined')
      &&
      (typeof (Blob) !== 'undefined')
      &&
      (typeof (FileList) !== 'undefined')
      &&
      (!!Blob.prototype.webkitSlice || !!Blob.prototype.mozSlice || !!Blob.prototype.slice || false)
    );
    if (!this.support) return false;


    // PROPERTIES
    const $ = this;
    $.files = [];
    $.defaults = {
      chunkSize: 1 * 1024 * 1024,
      forceChunkSize: false,
      simultaneousUploads: 3,
      fileParameterName: 'file',
      chunkNumberParameterName: 'resumableChunkNumber',
      chunkSizeParameterName: 'resumableChunkSize',
      currentChunkSizeParameterName: 'resumableCurrentChunkSize',
      totalSizeParameterName: 'resumableTotalSize',
      typeParameterName: 'resumableType',
      identifierParameterName: 'resumableIdentifier',
      fileNameParameterName: 'resumableFilename',
      relativePathParameterName: 'resumableRelativePath',
      totalChunksParameterName: 'resumableTotalChunks',
      dragOverClass: 'dragover',
      throttleProgressCallbacks: 0.5,
      query: {},
      headers: {},
      preprocess: null,
      preprocessFile: null,
      method: 'multipart',
      uploadMethod: 'POST',
      testMethod: 'GET',
      prioritizeFirstAndLastChunk: false,
      target: '/',
      testTarget: null,
      parameterNamespace: '',
      testChunks: true,
      generateUniqueIdentifier: null,
      getTarget: null,
      maxChunkRetries: 100,
      chunkRetryInterval: undefined,
      permanentErrors: [400, 401, 403, 404, 409, 415, 500, 501],
      maxFiles: undefined,
      withCredentials: false,
      xhrTimeout: 0,
      clearInput: true,
      chunkFormat: 'blob',
      setChunkTypeFromFile: false,
      maxFilesErrorCallback: function (files, errorCount) {
        const maxFiles = $.getOpt('maxFiles');
        alert('Please upload no more than ' + maxFiles + ' file' + (maxFiles === 1 ? '' : 's') + ' at a time.');
      },
      minFileSize: 1,
      minFileSizeErrorCallback: function (file, errorCount) {
        alert(file.fileName || file.name + ' is too small, please upload files larger than ' + $helpers.formatSize($.getOpt('minFileSize')) + '.');
      },
      maxFileSize: undefined,
      maxFileSizeErrorCallback: function (file, errorCount) {
        alert(file.fileName || file.name + ' is too large, please upload files less than ' + $helpers.formatSize($.getOpt('maxFileSize')) + '.');
      },
      fileType: [],
      fileTypeErrorCallback: function (file, errorCount) {
        alert(file.fileName || file.name + ' has type not allowed, please upload files of type ' + $.getOpt('fileType') + '.');
      }
    };
    $.opts = opts || {};
    $.getOpt = function (o) {
      let $opt = this;
      // Get multiple option if passed an array
      if (o instanceof Array) {
        const options = {};
        $helpers.each(o, function (option) {
          options[option] = $opt.getOpt(option);
        });
        return options;
      }
      // Otherwise, just return a simple option
      if ($opt instanceof ResumableChunk) {
        if (typeof $opt.opts[o] !== 'undefined') {
          return $opt.opts[o];
        } else {
          $opt = $opt.fileObj;
        }
      }
      if ($opt instanceof ResumableFile) {
        if (typeof $opt.opts[o] !== 'undefined') {
          return $opt.opts[o];
        } else {
          $opt = $opt.resumableObj;
        }
      }
      if ($opt instanceof Resumable) {
        if (typeof $opt.opts[o] !== 'undefined') {
          return $opt.opts[o];
        } else {
          return $opt.defaults[o];
        }
      }
    };
    $.indexOf = function (array, obj) {
      if (array.indexOf) {
        return array.indexOf(obj);
      }
      for (let i = 0; i < array.length; i++) {
        if (array[i] === obj) {
          return i;
        }
      }
      return -1;
    }

    // EVENTS
    // catchAll(event, ...)
    // fileSuccess(file), fileProgress(file), fileAdded(file, event), filesAdded(files, filesSkipped), fileRetry(file),
    // fileError(file, message), complete(), progress(), error(message, file), pause()
    $.events = [];
    $.on = function (event, callback) {
      $.events.push(event.toLowerCase(), callback);
    };
    $.fire = function () {
      // `arguments` is an object, not array, in FF, so:
      const args = [];
      for (let i = 0; i < arguments.length; i++) args.push(arguments[i]);
      // Find event listeners, and support pseudo-event `catchAll`
      const event = args[0].toLowerCase();
      for (let i = 0; i <= $.events.length; i += 2) {
        if ($.events[i] === event) $.events[i + 1].apply($, args.slice(1));
        if ($.events[i] === 'catchall') $.events[i + 1].apply(null, args);
      }
      if (event === 'fileerror') $.fire('error', args[2], args[1]);
      if (event === 'fileprogress') $.fire('progress');
    };


    // INTERNAL HELPER METHODS (handy, but ultimately not part of uploading)
    const $helpers = {
      stopEvent: function (e) {
        e.stopPropagation();
        e.preventDefault();
      },
      each: function (o, callback) {
        if (typeof (o.length) !== 'undefined') {
          for (var i = 0; i < o.length; i++) {
            // Array or FileList
            if (callback(o[i]) === false) return;
          }
        } else {
          for (i in o) {
            // Object
            if (callback(i, o[i]) === false) return;
          }
        }
      },
      generateUniqueIdentifier: function (file, event) {
        const custom = $.getOpt('generateUniqueIdentifier');
        if (typeof custom === 'function') {
          return custom(file, event);
        }
        const relativePath = file.webkitRelativePath || file.relativePath || file.fileName || file.name; // Some confusion in different versions of Firefox
        const size = file.size;
        return (`${size}-${relativePath.replace(/[^0-9a-zA-Z_-]/img, '')}`);
      },
      contains: function (array, test) {
        let result = false;

        $helpers.each(array, function (value) {
          if (value === test) {
            result = true;
            return false;
          }
          return true;
        });

        return result;
      },
      formatSize: function (size) {
        if (size < 1024) {
          return `${size} bytes`;
        } else if (size < 1024 * 1024) {
          return `${(size / 1024.0).toFixed(0)} KB`;
        } else if (size < 1024 * 1024 * 1024) {
          return `${(size / 1024.0 / 1024.0).toFixed(1)} MB`;
        } else {
          return `${(size / 1024.0 / 1024.0 / 1024.0).toFixed(1)} GB`;
        }
      },
      getTarget: function (request, params) {
        let target = $.getOpt('target');

        if (request === 'test' && $.getOpt('testTarget')) {
          target = $.getOpt('testTarget') === '/' ? $.getOpt('target') : $.getOpt('testTarget');
        }

        if (typeof target === 'function') {
          return target(params);
        }

        const separator = target.indexOf('?') < 0 ? '?' : '&';
        const joinedParams = params.join('&');

        if (joinedParams) target = target + separator + joinedParams;

        return target;
      }
    };

    const onDrop = function (e) {
      e.currentTarget.classList.remove($.getOpt('dragOverClass'));
      $helpers.stopEvent(e);

      //handle dropped things as items if we can (this lets us deal with folders nicer in some cases)
      if (e.dataTransfer && e.dataTransfer.items) {
        loadFiles(e.dataTransfer.items, event);
      }
      //else handle them as files
      else if (e.dataTransfer && e.dataTransfer.files) {
        loadFiles(e.dataTransfer.files, event);
      }
    };

    const onDragLeave = function (e) {
      e.currentTarget.classList.remove($.getOpt('dragOverClass'));
    };

    const onDragOverEnter = function (e) {
      e.preventDefault();
      const dt = e.dataTransfer;
      if ($.indexOf(dt.types, "Files") >= 0) { // only for file drop
        e.stopPropagation();
        dt.dropEffect = "copy";
        dt.effectAllowed = "copy";
        e.currentTarget.classList.add($.getOpt('dragOverClass'));
      } else { // not work on IE/Edge....
        dt.dropEffect = "none";
        dt.effectAllowed = "none";
      }
    };

    /**
     * processes a single upload item (file or directory)
     * @param {Object} item item to upload, may be file or directory entry
     * @param {string} path current file path
     * @param {File[]} items list of files to append new items to
     * @param {Function} cb callback invoked when item is processed
     */
    function processItem(item, path, items, cb) {
      let entry;
      if (item.isFile) {
        // file provided
        return item.file(function (file) {
          file.relativePath = path + file.name;
          items.push(file);
          cb();
        });
      } else if (item.isDirectory) {
        // item is already a directory entry, just assign
        entry = item;
      } else if (item instanceof File) {
        items.push(item);
      }
      if ('function' === typeof item.webkitGetAsEntry) {
        // get entry from file object
        entry = item.webkitGetAsEntry();
      }
      if (entry && entry.isDirectory) {
        // directory provided, process it
        return processDirectory(entry, path + entry.name + '/', items, cb);
      }
      if ('function' === typeof item.getAsFile) {
        // item represents a File object, convert it
        item = item.getAsFile();
        if (item instanceof File) {
          item.relativePath = path + item.name;
          items.push(item);
        }
      }
      cb(); // indicate processing is done
    }


    /**
     * cps-style list iteration.
     * invokes all functions in list and waits for their callback to be
     * triggered.
     * @param  {Function[]}   items list of functions expecting callback parameter
     * @param  {Function} cb    callback to trigger after the last callback has been invoked
     */
    function processCallbacks(items, cb) {
      if (!items || items.length === 0) {
        // empty or no list, invoke callback
        return cb();
      }
      // invoke current function, pass the next part as continuation
      items[0](function () {
        processCallbacks(items.slice(1), cb);
      });
    }

    /**
     * recursively traverse directory and collect files to upload
     * @param  {Object}   directory directory to process
     * @param  {string}   path      current path
     * @param  {File[]}   items     target list of items
     * @param  {Function} cb        callback invoked after traversing directory
     */
    function processDirectory(directory, path, items, cb) {
      const dirReader = directory.createReader();
      let allEntries = [];

      function readEntries() {
        dirReader.readEntries(function (entries) {
          if (entries.length) {
            allEntries = allEntries.concat(entries);
            return readEntries();
          }

          // process all conversion callbacks, finally invoke own one
          processCallbacks(
            allEntries.map(function (entry) {
              // bind all properties except for callback
              return processItem.bind(null, entry, path, items);
            }),
            cb
          );
        });
      }

      readEntries();
    }

    /**
     * process items to extract files to be uploaded
     * @param  {File[]} items items to process
     * @param  {Event} event event that led to upload
     */
    function loadFiles(items, event) {
      if (!items.length) {
        return; // nothing to do
      }
      $.fire('beforeAdd');
      const files = [];
      processCallbacks(
        Array.prototype.map.call(items, function (item) {
          // bind all properties except for callback
          let entry = item;
          if ('function' === typeof item.webkitGetAsEntry) {
            entry = item.webkitGetAsEntry();
          }
          return processItem.bind(null, entry, "", files);
        }),
        function () {
          if (files.length) {
            // at least one file found
            appendFilesFromFileList(files, event);
          }
        }
      );
    };

    const appendFilesFromFileList = function (fileList, event) {
      // check for uploading too many files
      let errorCount = 0;
      const options = $.getOpt(['maxFiles', 'minFileSize', 'maxFileSize', 'maxFilesErrorCallback', 'minFileSizeErrorCallback', 'maxFileSizeErrorCallback', 'fileType', 'fileTypeErrorCallback']);
      if (typeof (options.maxFiles) !== 'undefined' && options.maxFiles < (fileList.length + $.files.length)) {
        // if single-file upload, file is already added, and trying to add 1 new file, simply replace the already-added file
        if (options.maxFiles === 1 && $.files.length === 1 && fileList.length === 1) {
          $.removeFile($.files[0]);
        } else {
          options.maxFilesErrorCallback(fileList, errorCount++);
          return false;
        }
      }
      const files = [];
      const filesSkipped = [];
      let remaining = fileList.length;
      const decreaseReamining = function () {
        if (!--remaining) {
          // all files processed, trigger event
          if (!files.length && !filesSkipped.length) {
            // no succeeded files, just skip
            return;
          }
          window.setTimeout(function () {
            $.fire('filesAdded', files, filesSkipped);
          }, 0);
        }
      };
      $helpers.each(fileList, function (file) {
        const fileName = file.name;
        const fileType = file.type; // e.g video/mp4
        if (options.fileType.length > 0) {
          let fileTypeFound = false;
          for (const index in options.fileType) {
            // For good behaviour we do some inital sanitizing. Remove spaces and lowercase all
            options.fileType[index] = options.fileType[index].replace(/\s/g, '').toLowerCase();

            // Allowing for both [extension, .extension, mime/type, mime/*]
            const extension = ((options.fileType[index].match(/^[^.][^/]+$/)) ? '.' : '') + options.fileType[index];

            if ((fileName.substr(-1 * extension.length).toLowerCase() === extension) ||
              //If MIME type, check for wildcard or if extension matches the files tiletype
              (extension.indexOf('/') !== -1 && (
                (extension.indexOf('*') !== -1 && fileType.substr(0, extension.indexOf('*')) === extension.substr(0, extension.indexOf('*'))) ||
                fileType === extension
              ))
            ) {
              fileTypeFound = true;
              break;
            }
          }
          if (!fileTypeFound) {
            options.fileTypeErrorCallback(file, errorCount++);
            return true;
          }
        }

        if (typeof (options.minFileSize) !== 'undefined' && file.size < options.minFileSize) {
          options.minFileSizeErrorCallback(file, errorCount++);
          return true;
        }
        if (typeof (options.maxFileSize) !== 'undefined' && file.size > options.maxFileSize) {
          options.maxFileSizeErrorCallback(file, errorCount++);
          return true;
        }

        function addFile(uniqueIdentifier) {
          if (!$.getFromUniqueIdentifier(uniqueIdentifier)) {
            (function () {
              file.uniqueIdentifier = uniqueIdentifier;
              const resumableFile = new ResumableFile($, file, uniqueIdentifier);
              $.files.push(resumableFile);
              files.push(resumableFile);
              resumableFile.container = (typeof event != 'undefined' ? event.srcElement : null);
              window.setTimeout(function () {
                $.fire('fileAdded', resumableFile, event)
              }, 0);
            })()
          } else {
            filesSkipped.push(file);
          }
          decreaseReamining();
        }

        // directories have size == 0
        const uniqueIdentifier = $helpers.generateUniqueIdentifier(file, event);
        if (uniqueIdentifier && typeof uniqueIdentifier.then === 'function') {
          // Promise or Promise-like object provided as unique identifier
          uniqueIdentifier
            .then(
              function (uniqueIdentifier) {
                // unique identifier generation succeeded
                addFile(uniqueIdentifier);
              },
              function () {
                // unique identifier generation failed
                // skip further processing, only decrease file count
                decreaseReamining();
              }
            );
        } else {
          // non-Promise provided as unique identifier, process synchronously
          addFile(uniqueIdentifier);
        }
      });
    };

    // INTERNAL OBJECT TYPES
    function ResumableFile(resumableObj, file, uniqueIdentifier) {
      const $ = this;
      $.opts = {};
      $.getOpt = resumableObj.getOpt;
      $._prevProgress = 0;
      $.resumableObj = resumableObj;
      $.file = file;
      $.fileName = file.fileName || file.name; // Some confusion in different versions of Firefox
      $.size = file.size;
      $.relativePath = file.relativePath || file.webkitRelativePath || $.fileName;
      $.uniqueIdentifier = uniqueIdentifier;
      $._pause = false;
      $.container = '';
      $.preprocessState = 0; // 0 = unprocessed, 1 = processing, 2 = finished
      let _error = uniqueIdentifier !== undefined;

      // Callback when something happens within the chunk
      const chunkEvent = function (event, message) {
        // event can be 'progress', 'success', 'error' or 'retry'
        switch (event) {
          case 'progress':
            $.resumableObj.fire('fileProgress', $, message);
            break;
          case 'error':
            $.abort();
            _error = true;
            $.chunks = [];
            $.resumableObj.fire('fileError', $, message);
            break;
          case 'success':
            if (_error) return;
            $.resumableObj.fire('fileProgress', $, message); // it's at least progress
            if ($.isComplete()) {
              $.resumableObj.fire('fileSuccess', $, message);
            }
            break;
          case 'retry':
            $.resumableObj.fire('fileRetry', $);
            break;
        }
      };

      // Main code to set up a file object with chunks,
      // packaged to be able to handle retries if needed.
      $.chunks = [];
      $.abort = function () {
        // Stop current uploads
        let abortCount = 0;
        $helpers.each($.chunks, function (c) {
          if (c.status() === 'uploading') {
            c.abort();
            abortCount++;
          }
        });
        if (abortCount > 0) $.resumableObj.fire('fileProgress', $);
      };
      $.cancel = function () {
        // Reset this file to be void
        const _chunks = $.chunks;
        $.chunks = [];
        // Stop current uploads
        $helpers.each(_chunks, function (c) {
          if (c.status() === 'uploading') {
            c.abort();
            $.resumableObj.uploadNextChunk();
          }
        });
        $.resumableObj.removeFile($);
        $.resumableObj.fire('fileProgress', $);
      };
      $.retry = function () {
        $.bootstrap();
        let firedRetry = false;
        $.resumableObj.on('chunkingComplete', function () {
          if (!firedRetry) $.resumableObj.upload();
          firedRetry = true;
        });
      };
      $.bootstrap = function () {
        $.abort();
        _error = false;
        // Rebuild stack of chunks from file
        $.chunks = [];
        $._prevProgress = 0;
        const round = $.getOpt('forceChunkSize') ? Math.ceil : Math.floor;
        const maxOffset = Math.max(round($.file.size / $.getOpt('chunkSize')), 1);
        for (let offset = 0; offset < maxOffset; offset++) {
          (function (offset) {
            window.setTimeout(function () {
              $.chunks.push(new ResumableChunk($.resumableObj, $, offset, chunkEvent));
              $.resumableObj.fire('chunkingProgress', $, offset / maxOffset);
            }, 0);
          })(offset)
        }
        window.setTimeout(function () {
          $.resumableObj.fire('chunkingComplete', $);
        }, 0);
      };
      $.progress = function () {
        if (_error) return (1);
        // Sum up progress across everything
        let ret = 0;
        let error = false;
        $helpers.each($.chunks, function (c) {
          if (c.status() === 'error') error = true;
          ret += c.progress(true); // get chunk progress relative to entire file
        });
        ret = (error ? 1 : (ret > 0.99999 ? 1 : ret));
        ret = Math.max($._prevProgress, ret); // We don't want to lose percentages when an upload is paused
        $._prevProgress = ret;
        return (ret);
      };
      $.isUploading = function () {
        var uploading = false;
        $helpers.each($.chunks, function (chunk) {
          if (chunk.status() === 'uploading') {
            uploading = true;
            return false;
          }
        });
        return (uploading);
      };
      $.isComplete = function () {
        let outstanding = false;
        if ($.preprocessState === 1) {
          return false;
        }
        $helpers.each($.chunks, function (chunk) {
          const status = chunk.status();
          if (status === 'pending' || status === 'uploading' || chunk.preprocessState === 1) {
            outstanding = true;
            return false;
          }
        });
        return (!outstanding);
      };
      $.pause = function (pause) {
        if (typeof (pause) === 'undefined') {
          $._pause = !$._pause;
        } else {
          $._pause = pause;
        }
      };
      $.isPaused = function () {
        return $._pause;
      };
      $.preprocessFinished = function () {
        $.preprocessState = 2;
        $.upload();
      };
      $.upload = function () {
        let found = false;
        if ($.isPaused() === false) {
          const preprocess = $.getOpt('preprocessFile');
          if (typeof preprocess === 'function') {
            switch ($.preprocessState) {
              case 0:
                $.preprocessState = 1;
                preprocess($);
                return true;
              case 1:
                return true;
              case 2:
                break;
            }
          }
          $helpers.each($.chunks, function (chunk) {
            if (chunk.status() === 'pending' && chunk.preprocessState !== 1) {
              chunk.send();
              found = true;
              return (false);
            }
          });
        }
        return (found);
      }
      $.markChunksCompleted = function (chunkNumber) {
        if (!$.chunks || $.chunks.length <= chunkNumber) {
          return;
        }
        for (let num = 0; num < chunkNumber; num++) {
          $.chunks[num].markComplete = true;
        }
      };

      // Bootstrap and return
      $.resumableObj.fire('chunkingStart', $);
      $.bootstrap();
      return (this);
    }


    function ResumableChunk(resumableObj, fileObj, offset, callback) {
      const $ = this;
      $.opts = {};
      $.getOpt = resumableObj.getOpt;
      $.resumableObj = resumableObj;
      $.fileObj = fileObj;
      $.fileObjSize = fileObj.size;
      $.fileObjType = fileObj.file.type;
      $.offset = offset;
      $.callback = callback;
      $.lastProgressCallback = (new Date);
      $.tested = false;
      $.retries = 0;
      $.pendingRetry = false;
      $.preprocessState = 0; // 0 = unprocessed, 1 = processing, 2 = finished
      $.markComplete = false;

      // Computed properties
      const chunkSize = $.getOpt('chunkSize');
      $.loaded = 0;
      $.startByte = $.offset * chunkSize;
      $.endByte = Math.min($.fileObjSize, ($.offset + 1) * chunkSize);
      if ($.fileObjSize - $.endByte < chunkSize && !$.getOpt('forceChunkSize')) {
        // The last chunk will be bigger than the chunk size, but less than 2*chunkSize
        $.endByte = $.fileObjSize;
      }
      $.xhr = null;

      // test() makes a GET request without any data to see if the chunk has already been uploaded in a previous session
      $.test = function () {
        // Set up request and listen for event
        $.xhr = new XMLHttpRequest();

        const testHandler = function (e) {
          $.tested = true;
          const status = $.status();
          if (status === 'success') {
            $.callback(status, $.message());
            $.resumableObj.uploadNextChunk();
          } else {
            $.send();
          }
        };
        $.xhr.addEventListener('load', testHandler, false);
        $.xhr.addEventListener('error', testHandler, false);
        $.xhr.addEventListener('timeout', testHandler, false);

        // Add data from the query options
        let params = [];
        const parameterNamespace = $.getOpt('parameterNamespace');
        let customQuery = $.getOpt('query');
        if (typeof customQuery === 'function') customQuery = customQuery($.fileObj, $);
        $helpers.each(customQuery, function (k, v) {
          params.push([encodeURIComponent(parameterNamespace + k), encodeURIComponent(v)].join('='));
        });
        // Add extra data to identify chunk
        params = params.concat(
          [
            // define key/value pairs for additional parameters
            ['chunkNumberParameterName', $.offset + 1],
            ['chunkSizeParameterName', $.getOpt('chunkSize')],
            ['currentChunkSizeParameterName', $.endByte - $.startByte],
            ['totalSizeParameterName', $.fileObjSize],
            ['typeParameterName', $.fileObjType],
            ['identifierParameterName', $.fileObj.uniqueIdentifier],
            ['fileNameParameterName', $.fileObj.fileName],
            ['relativePathParameterName', $.fileObj.relativePath],
            ['totalChunksParameterName', $.fileObj.chunks.length]
          ].filter(function (pair) {
            // include items that resolve to truthy values
            // i.e. exclude false, null, undefined and empty strings
            return $.getOpt(pair[0]);
          })
            .map(function (pair) {
              // map each key/value pair to its final form
              return [
                parameterNamespace + $.getOpt(pair[0]),
                encodeURIComponent(pair[1])
              ].join('=');
            })
        );
        // Append the relevant chunk and send it
        $.xhr.open($.getOpt('testMethod'), $helpers.getTarget('test', params));
        $.xhr.timeout = $.getOpt('xhrTimeout');
        $.xhr.withCredentials = $.getOpt('withCredentials');
        // Add data from header options
        let customHeaders = $.getOpt('headers');
        if (typeof customHeaders === 'function') {
          customHeaders = customHeaders($.fileObj, $);
        }
        $helpers.each(customHeaders, function (k, v) {
          $.xhr.setRequestHeader(k, v);
        });
        $.xhr.send(null);
      };

      $.preprocessFinished = function () {
        $.preprocessState = 2;
        $.send();
      };

      // send() uploads the actual data in a POST call
      $.send = function () {
        const preprocess = $.getOpt('preprocess');
        if (typeof preprocess === 'function') {
          switch ($.preprocessState) {
            case 0:
              $.preprocessState = 1;
              preprocess($);
              return;
            case 1:
              return;
            case 2:
              break;
          }
        }
        if ($.getOpt('testChunks') && !$.tested) {
          $.test();
          return;
        }

        // Set up request and listen for event
        $.xhr = new XMLHttpRequest();

        // Progress
        $.xhr.upload.addEventListener('progress', function (e) {
          if ((new Date) - $.lastProgressCallback > $.getOpt('throttleProgressCallbacks') * 1000) {
            $.callback('progress');
            $.lastProgressCallback = (new Date);
          }
          $.loaded = e.loaded || 0;
        }, false);
        $.loaded = 0;
        $.pendingRetry = false;
        $.callback('progress');

        // Done (either done, failed or retry)
        const doneHandler = function (e) {
          const status = $.status();
          if (status === 'success' || status === 'error') {
            $.callback(status, $.message());
            $.resumableObj.uploadNextChunk();
          } else {
            $.callback('retry', $.message());
            $.abort();
            $.retries++;
            const retryInterval = $.getOpt('chunkRetryInterval');
            if (retryInterval !== undefined) {
              $.pendingRetry = true;
              setTimeout($.send, retryInterval);
            } else {
              $.send();
            }
          }
        };
        $.xhr.addEventListener('load', doneHandler, false);
        $.xhr.addEventListener('error', doneHandler, false);
        $.xhr.addEventListener('timeout', doneHandler, false);

        // Set up the basic query data from Resumable
        const query = [
          ['chunkNumberParameterName', $.offset + 1],
          ['chunkSizeParameterName', $.getOpt('chunkSize')],
          ['currentChunkSizeParameterName', $.endByte - $.startByte],
          ['totalSizeParameterName', $.fileObjSize],
          ['typeParameterName', $.fileObjType],
          ['identifierParameterName', $.fileObj.uniqueIdentifier],
          ['fileNameParameterName', $.fileObj.fileName],
          ['relativePathParameterName', $.fileObj.relativePath],
          ['totalChunksParameterName', $.fileObj.chunks.length],
        ].filter(function (pair) {
          // include items that resolve to truthy values
          // i.e. exclude false, null, undefined and empty strings
          return $.getOpt(pair[0]);
        })
          .reduce(function (query, pair) {
            // assign query key/value
            query[$.getOpt(pair[0])] = pair[1];
            return query;
          }, {});
        // Mix in custom data
        let customQuery = $.getOpt('query');
        if (typeof customQuery === 'function') customQuery = customQuery($.fileObj, $);
        $helpers.each(customQuery, function (k, v) {
          query[k] = v;
        });

        const func = ($.fileObj.file.slice ? 'slice' : ($.fileObj.file.mozSlice ? 'mozSlice' : ($.fileObj.file.webkitSlice ? 'webkitSlice' : 'slice')));
        const bytes = $.fileObj.file[func]($.startByte, $.endByte, $.getOpt('setChunkTypeFromFile') ? $.fileObj.file.type : "");
        let data = null;
        const params = [];

        const parameterNamespace = $.getOpt('parameterNamespace');
        if ($.getOpt('method') === 'octet') {
          // Add data from the query options
          data = bytes;
          $helpers.each(query, function (k, v) {
            params.push([encodeURIComponent(parameterNamespace + k), encodeURIComponent(v)].join('='));
          });
        } else {
          // Add data from the query options
          data = new FormData();
          $helpers.each(query, function (k, v) {
            data.append(parameterNamespace + k, v);
            params.push([encodeURIComponent(parameterNamespace + k), encodeURIComponent(v)].join('='));
          });
          if ($.getOpt('chunkFormat') === 'blob') {
            data.append(parameterNamespace + $.getOpt('fileParameterName'), bytes, $.fileObj.fileName);
          } else if ($.getOpt('chunkFormat') === 'base64') {
            const fr = new FileReader();
            fr.onload = function (e) {
              data.append(parameterNamespace + $.getOpt('fileParameterName'), fr.result);
              $.xhr.send(data);
            }
            fr.readAsDataURL(bytes);
          }
        }

        const target = $helpers.getTarget('upload', params);
        const method = $.getOpt('uploadMethod');

        $.xhr.open(method, target);
        if ($.getOpt('method') === 'octet') {
          $.xhr.setRequestHeader('Content-Type', 'application/octet-stream');
        }
        $.xhr.timeout = $.getOpt('xhrTimeout');
        $.xhr.withCredentials = $.getOpt('withCredentials');
        // Add data from header options
        let customHeaders = $.getOpt('headers');
        if (typeof customHeaders === 'function') {
          customHeaders = customHeaders($.fileObj, $);
        }

        $helpers.each(customHeaders, function (k, v) {
          $.xhr.setRequestHeader(k, v);
        });

        if ($.getOpt('chunkFormat') === 'blob') {
          $.xhr.send(data);
        }
      };
      $.abort = function () {
        // Abort and reset
        if ($.xhr) $.xhr.abort();
        $.xhr = null;
      };
      $.status = function () {
        // Returns: 'pending', 'uploading', 'success', 'error'
        if ($.pendingRetry) {
          // if pending retry then that's effectively the same as actively uploading,
          // there might just be a slight delay before the retry starts
          return ('uploading');
        } else if ($.markComplete) {
          return 'success';
        } else if (!$.xhr) {
          return ('pending');
        } else if ($.xhr.readyState < 4) {
          // Status is really 'OPENED', 'HEADERS_RECEIVED' or 'LOADING' - meaning that stuff is happening
          return ('uploading');
        } else {
          if ($.xhr.status === 200 || $.xhr.status === 201) {
            // HTTP 200, 201 (created)
            return ('success');
          } else if ($helpers.contains($.getOpt('permanentErrors'), $.xhr.status) || $.retries >= $.getOpt('maxChunkRetries')) {
            // HTTP 400, 404, 409, 415, 500, 501 (permanent error)
            return ('error');
          } else {
            // this should never happen, but we'll reset and queue a retry
            // a likely case for this would be 503 service unavailable
            $.abort();
            return ('pending');
          }
        }
      };
      $.message = function () {
        return ($.xhr ? $.xhr.responseText : '');
      };
      $.progress = function (relative) {
        if (typeof (relative) === 'undefined') relative = false;
        let factor = (relative ? ($.endByte - $.startByte) / $.fileObjSize : 1);
        if ($.pendingRetry) return (0);
        if ((!$.xhr || !$.xhr.status) && !$.markComplete) factor *= .95;
        const s = $.status();
        switch (s) {
          case 'success':
          case 'error':
            return 1 * factor;
          case 'pending':
            return 0;
          default:
            return ($.loaded / ($.endByte - $.startByte) * factor);
        }
      };
      return (this);
    }

    // QUEUE
    $.uploadNextChunk = function () {
      let found = false;

      // In some cases (such as videos) it's really handy to upload the first
      // and last chunk of a file quickly; this let's the server check the file's
      // metadata and determine if there's even a point in continuing.
      if ($.getOpt('prioritizeFirstAndLastChunk')) {
        $helpers.each($.files, function (file) {
          if (file.chunks.length && file.chunks[0].status() === 'pending' && file.chunks[0].preprocessState === 0) {
            file.chunks[0].send();
            found = true;
            return false;
          }
          if (file.chunks.length > 1 && file.chunks[file.chunks.length - 1].status() === 'pending' && file.chunks[file.chunks.length - 1].preprocessState === 0) {
            file.chunks[file.chunks.length - 1].send();
            found = true;
            return false;
          }
        });
        if (found) return true;
      }

      // Now, simply look for the next, best thing to upload
      $helpers.each($.files, function (file) {
        found = file.upload();
        if (found) return false;
      });
      if (found) return true;

      // The are no more outstanding chunks to upload, check is everything is done
      let outstanding = false;
      $helpers.each($.files, function (file) {
        if (!file.isComplete()) {
          outstanding = true;
          return false;
        }
      });
      if (!outstanding) {
        // All chunks have been uploaded, complete
        $.fire('complete');
      }
      return false;
    };


    // PUBLIC METHODS FOR RESUMABLE.JS
    $.assignBrowse = function (domNodes, isDirectory) {
      if (typeof (domNodes.length) == 'undefined') domNodes = [domNodes];
      $helpers.each(domNodes, function (domNode) {
        let input;
        if (domNode.tagName === 'INPUT' && domNode.type === 'file') {
          input = domNode;
        } else {
          input = document.createElement('input');
          input.setAttribute('type', 'file');
          input.style.display = 'none';
          domNode.addEventListener('click', function () {
            input.style.opacity = 0;
            input.style.display = 'block';
            input.focus();
            input.click();
            input.style.display = 'none';
          }, false);
          domNode.appendChild(input);
        }
        const maxFiles = $.getOpt('maxFiles');
        if (typeof (maxFiles) === 'undefined' || maxFiles !== 1) {
          input.setAttribute('multiple', 'multiple');
        } else {
          input.removeAttribute('multiple');
        }
        if (isDirectory) {
          input.setAttribute('webkitdirectory', 'webkitdirectory');
        } else {
          input.removeAttribute('webkitdirectory');
        }
        const fileTypes = $.getOpt('fileType');
        if (typeof (fileTypes) !== 'undefined' && fileTypes.length >= 1) {
          input.setAttribute('accept', fileTypes.map(function (e) {
            e = e.replace(/\s/g, '').toLowerCase();
            if (e.match(/^[^.][^/]+$/)) {
              e = '.' + e;
            }
            return e;
          }).join(','));
        } else {
          input.removeAttribute('accept');
        }
        // When new files are added, simply append them to the overall list
        input.addEventListener('change', function (e) {
          appendFilesFromFileList(e.target.files, e);
          const clearInput = $.getOpt('clearInput');
          if (clearInput) {
            e.target.value = '';
          }
        }, false);
      });
    };
    $.assignDrop = function (domNodes) {
      if (typeof (domNodes.length) == 'undefined') domNodes = [domNodes];

      $helpers.each(domNodes, function (domNode) {
        domNode.addEventListener('dragover', onDragOverEnter, false);
        domNode.addEventListener('dragenter', onDragOverEnter, false);
        domNode.addEventListener('dragleave', onDragLeave, false);
        domNode.addEventListener('drop', onDrop, false);
      });
    };
    $.unAssignDrop = function (domNodes) {
      if (typeof (domNodes.length) == 'undefined') domNodes = [domNodes];

      $helpers.each(domNodes, function (domNode) {
        domNode.removeEventListener('dragover', onDragOverEnter);
        domNode.removeEventListener('dragenter', onDragOverEnter);
        domNode.removeEventListener('dragleave', onDragLeave);
        domNode.removeEventListener('drop', onDrop);
      });
    };
    $.isUploading = function () {
      let uploading = false;
      $helpers.each($.files, function (file) {
        if (file.isUploading()) {
          uploading = true;
          return false;
        }
      });
      return (uploading);
    };
    $.upload = function () {
      // Make sure we don't start too many uploads at once
      if ($.isUploading()) return;
      // Kick off the queue
      $.fire('uploadStart');
      for (let num = 1; num <= $.getOpt('simultaneousUploads'); num++) {
        $.uploadNextChunk();
      }
    };
    $.pause = function () {
      // Resume all chunks currently being uploaded
      $helpers.each($.files, function (file) {
        file.abort();
      });
      $.fire('pause');
    };
    $.cancel = function () {
      $.fire('beforeCancel');
      for (let i = $.files.length - 1; i >= 0; i--) {
        $.files[i].cancel();
      }
      $.fire('cancel');
    };
    $.progress = function () {
      let totalDone = 0;
      let totalSize = 0;
      // Resume all chunks currently being uploaded
      $helpers.each($.files, function (file) {
        totalDone += file.progress() * file.size;
        totalSize += file.size;
      });
      return (totalSize > 0 ? totalDone / totalSize : 0);
    };
    $.addFile = function (file, event) {
      appendFilesFromFileList([file], event);
    };
    $.addFiles = function (files, event) {
      appendFilesFromFileList(files, event);
    };
    $.removeFile = function (file) {
      for (let i = $.files.length - 1; i >= 0; i--) {
        if ($.files[i] === file) {
          $.files.splice(i, 1);
        }
      }
    };
    $.getFromUniqueIdentifier = function (uniqueIdentifier) {
      let ret = false;
      $helpers.each($.files, function (f) {
        if (f.uniqueIdentifier === uniqueIdentifier) ret = f;
      });
      return (ret);
    };
    $.getSize = function () {
      let totalSize = 0;
      $helpers.each($.files, function (file) {
        totalSize += file.size;
      });
      return (totalSize);
    };
    $.handleDropEvent = function (e) {
      onDrop(e);
    };
    $.handleChangeEvent = function (e) {
      appendFilesFromFileList(e.target.files, e);
      e.target.value = '';
    };
    $.updateQuery = function (query) {
      $.opts.query = query;
    };

    return (this);
  };


  // Node.js-style export for Node and Component
  if (typeof module != 'undefined') {
    // left here for backwards compatibility
    module.exports = Resumable;
    module.exports.Resumable = Resumable;
  } else if (typeof define === "function" && define.amd) {
    // AMD/requirejs: Define the module
    define(function () {
      return Resumable;
    });
  } else {
    // Browser: Expose to window
    window.Resumable = Resumable;
  }

})();
