/**
 * Derived from: https://github.com/mailopl/html5-xhr2-chunked-file-upload-slice
 * by Marcin Wawrzyniak
 */

(function ($) {
  $(document).ready(function () {
    $('.form-upload-button').click(function() {
      var context = $(this).parent();
      var element = $('.form-upload-file', context).get(0);

      if (element.files[0] != undefined) {
        sendRequest(element, context);
        $(this).attr('disabled', 'disabled');
      }
      else {
        alert('Please select a file to upload.');
      }
    });
  });

  const BYTES_PER_CHUNK = 1024 * 1024; // 1MB chunk sizes.

  /**
   * Calculates slices and indirectly uploads a chunk of a file via uploadFile()
   */
  function sendRequest(element, context) {
    var blob = element.files[0];
    var start = 0;
    var end;
    var index = 0;
    blob.slices = 0; // slices, value that gets decremented
    blob.slicesTotal = 0; // total amount of slices, constant once calculated
    blob.uniq_id = uuid(); // file unique identifier, used server side

    // calculate the number of slices
    blob.slices = Math.ceil(blob.size / BYTES_PER_CHUNK);
    blob.slicesTotal = blob.slices;

    while(start < blob.size) {
      end = start + BYTES_PER_CHUNK;
      if (end > blob.size) {
        end = blob.size;
      }

      uploadFile(blob, index, start, end, context);

      start = end;
      index++;
    }
  }

  /**
   * Blob to ArrayBuffer (needed ex. on Android 4.0.4)
   */
  var str2ab_blobreader = function(str, callback) {
    var blob;
    BlobBuilder = window.MozBlobBuilder || window.WebKitBlobBuilder || window.BlobBuilder;
    if (typeof(BlobBuilder) !== 'undefined') {
      var bb = new BlobBuilder();
      bb.append(str);
      blob = bb.getBlob();
    }
    else {
      blob = new Blob([str]);
    }
    var f = new FileReader();
    f.onload = function(e) {
      callback(e.target.result)
    }
    f.readAsArrayBuffer(blob);
  }

  /**
   * Performs actual upload, adjusts progress bars
   *
   * @param blob
   * @param index
   * @param start
   * @param end
   */
  function uploadFile(blob, index, start, end, context) {
    var end;
    var chunk;
    var fileData;
    var endpoint = "/upload?" +
      "id=" + blob.uniq_id + "&" +
      "size=" + blob.size + "&" + // full size
      "index=" + index // part identifier
    ;

    if (blob.webkitSlice) {
      chunk = blob.webkitSlice(start, end);
    }
    else if (blob.mozSlice) {
      chunk = blob.mozSlice(start, end);
    }
    else {
      chunk = blob.slice(start, end);
    }

    if (blob.webkitSlice) { // android default browser in version 4.0.4 has webkitSlice instead of slice()
      var buffer = str2ab_blobreader(chunk, function(buf) { // we cannot send a blob, because body payload will be empty
        fileData = buf; // thats why we send an ArrayBuffer
      });  
    }
    else {
      fileData = chunk; // but if we support slice() everything should be ok
    }

    var percentageDiv = $('.form-upload-percent', context);
    var progressBar = $('.form-upload-progress', context);

    $.ajax({
      url: endpoint,  
      type: 'POST',
      xhr: function() {  // custom xhr
        var xhr = $.ajaxSettings.xhr();
        if (xhr.upload) { // if upload property exists
          xhr.upload.addEventListener('progress', function(evt) {
            if (evt.lengthComputable) {
              $(progressBar).attr('max', blob.slicesTotal);
              $(progressBar).val(index);
              $(percentageDiv).html(Math.round(index/blob.slicesTotal * 100) + "%");
            }
          }, false); // progressbar
        }
        return xhr;
      },
      //Ajax events
      success: function(data) {
        data = $.parseJSON(data);
        if (data.success) {
          blob.slices--;

          // if we have finished all slices
          if (blob.slices == 0) {
            mergeFile(blob, context);
          }
        }
        else {
          if (data.success) {
            alert('Operation failed! Reason: ' + data.error);
          }
          else {
            alert('Operation failed!');
          }
        }
      },
      error: function() {
        alert('Operation error. Please try again later.');
      },
      // File data
      data: fileData,
      //Options to tell JQuery not to process data or worry about content-type
      cache: false,
      contentType: false,
      processData: false
    });
  }

  /**
   * Function executed once all of the slices has been sent, "TO MERGE THEM ALL!"
   */
  function mergeFile(blob, context) {
    var endpoint = "/merge?" +
      "name=" + encodeURIComponent(blob.name) + "&" + // filename
      "id=" + blob.uniq_id + "&" + // unique upload identifier
      "index=" + blob.slicesTotal // part identifier
    ;

    var percentageDiv = $('.form-upload-percent', context);
    var progressBar = $('.form-upload-progress', context);

    /* Fetch auth token */
    $.ajax({
      type: 'GET',
      url: endpoint,
      success: function (data) {
        if (data.success) {
          $(progressBar).attr('max', 100);
          $(progressBar).val(100);
          $(percentageDiv).html('100%');

          $('.form-upload-button', context).removeAttr('disabled');
          alert('File uploaded successfully!');
        }
        else {
          if (data.success) {
            alert('Operation failed! Reason: ' + data.error);
          }
          else {
            alert('Operation failed!');
          }
        }
      },
      error: function() {
        alert('Operation error. Please try again later.');
      },
    });
  }
})(jQuery);
