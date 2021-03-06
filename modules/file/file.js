/**
 * Derived from: https://github.com/mailopl/html5-xhr2-chunked-file-upload-slice
 * by Marcin Wawrzyniak
 */

(function ($) {
  $(document).ready(function () {
    $('.form-upload-button').click(function() {
      var context = $(this).parent();
      var element = $('.form-upload-file', context).get(0);
      var statusDiv = $('.form-upload-status', context);

      /* Clear status messages */
      $(statusDiv).html('');

      if (element.files[0] != undefined) {
        sendRequest(element, context);
        $('button', context).attr('disabled', 'disabled');
      }
      else {
        alert('Please select a file to upload.');
      }
    });

    $('.form-delete-button').click(function() {
      var context = $(this).parent();
      var element = $('.form-upload-file', context);
      var statusDiv = $('.form-upload-status', context);

      /* Clear status messages */
      $(statusDiv).html('');

      element.entity_id = $('.form-upload-entity-id', context).val();
      if (element.entity_id) {
        deleteFile(element, context);
        $('button', context).attr('disabled', 'disabled');
      }
      else {
        $(statusDiv).html('<span class="error">There is no file to delete!</span>');
      }
    });
  });

  const BYTES_PER_CHUNK = Ophal.settings.core.BYTES_PER_CHUNK;

  /**
   * Calculates slices and indirectly uploads a chunk of a file via uploadFile()
   */
  function sendRequest(element, context) {
    var blob = element.files[0];
    blob.start = 0;
    blob.index = 0;
    blob.slices = 0; /* slices, value that gets decremented */
    blob.slicesTotal = 0; /* total amount of slices, constant once calculated */
    blob.uniq_id = uuid(); /* file unique identifier, used server side */

    /* calculate the number of slices */
    blob.slices = Math.ceil(blob.size / BYTES_PER_CHUNK);
    blob.slicesTotal = blob.slices;

    uploadContinue(blob, context);
  }

  function uploadContinue(blob, context) {
    if (blob.start < blob.size) {
      blob.end = blob.start + BYTES_PER_CHUNK;
      if (blob.end > blob.size) {
        blob.end = blob.size;
      }

      uploadFile(blob, context);

      blob.start = blob.end;
      blob.index++;
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
   * @param context
   */
  function uploadFile(blob, context) {
    var chunk;
    var fileData;
    var endpoint = "/file/upload?" +
      "name=" + encodeURIComponent(blob.name) + "&" + /* filename */
      "id=" + blob.uniq_id + "&" +
      "index=" + blob.index /* part identifier */
    ;

    if (blob.webkitSlice) {
      chunk = blob.webkitSlice(blob.start, blob.end);
    }
    else if (blob.mozSlice) {
      chunk = blob.mozSlice(blob.start, blob.end);
    }
    else {
      chunk = blob.slice(blob.start, blob.end);
    }

    if (blob.webkitSlice) { /* android default browser in version 4.0.4 has webkitSlice instead of slice() */
      var buffer = str2ab_blobreader(chunk, function(buf) { /* we cannot send a blob, because body payload will be empty */
        fileData = buf; /* thats why we send an ArrayBuffer */
      });  
    }
    else {
      fileData = chunk; /* but if we support slice() everything should be ok */
    }

    var statusDiv = $('.form-upload-status', context);
    var progressBar = $('.form-upload-progress', context);

    $.ajax({
      url: endpoint,
      type: 'POST',
      /* Ajax events */
      success: function(data) {
        if (data.success) {
          blob.slices--;

          if (blob.slices == 0) {
            /* merge slices finished all slices */
            mergeFile(blob, context);
          }
          else {
            /* otherwise keep uploading */
            uploadContinue(blob, context);
          }

          if (blob.slices > 1) {
            /* progress bar */
            $(progressBar).attr('max', blob.slicesTotal);
            $(progressBar).val(blob.index);
            $(statusDiv).html(Math.round(blob.index/blob.slicesTotal * 100) + "%");
          }
        }
        else {
          /* Allow to try again */
          $('button', context).removeAttr('disabled');

          if (data.error) {
            $(statusDiv).html('<span class="error">Operation failed! Reason: ' + data.error + '</span>');
          }
          else {
            $(statusDiv).html('<span class="error">Operation failed!</span>');
          }
        }
      },
      error: function() {
        $(statusDiv).html('<span class="error">Operation error. Please try again later.</span>');
      },
      /* File data */
      data: fileData,
      /* Options to tell JQuery not to process data or worry about content-type */
      cache: false,
      contentType: false,
      processData: false
    });
  }

  /**
   * Function executed once all of the slices has been sent, "TO MERGE THEM ALL!"
   */
  function mergeFile(blob, context) {
    var endpoint = "/file/merge?" +
      "name=" + encodeURIComponent(blob.name) + "&" + /* filename */
      "id=" + blob.uniq_id + "&" + /* unique upload identifier */
      "size=" + blob.size + "&" + /* full size */
      "index=" + blob.slicesTotal /* part identifier */
    ;

    var statusDiv = $('.form-upload-status', context);
    var progressBar = $('.form-upload-progress', context);

    /* Fetch auth token */
    $.ajax({
      type: 'GET',
      url: endpoint,
      success: function (data) {
        if (data.success) {
          $('.form-upload-entity-id', context).val(data.id);

          $(progressBar).attr('max', 100);
          $(progressBar).val(100);
          $(statusDiv).html('File uploaded successfully!');
        }
        else {
          /* Allow to try again */
          $('button', context).removeAttr('disabled');

          if (data.error) {
            $(statusDiv).html('<span class="error">Operation failed! Reason: ' + data.error + '</span>');
          }
          else {
            $(statusDiv).html('<span class="error">Operation failed!</span>');
          }
        }
      },
      error: function() {
        $(statusDiv).html('<span class="error">Operation error. Please try again later.</span>');
      },
    });
  }

  /**
   */
  function deleteFile(element, context) {
    var endpoint = "/file/delete?" +
      "id=" + element.entity_id
    ;

    var statusDiv = $('.form-upload-status', context);

    /* Fetch auth token */
    $.ajax({
      type: 'GET',
      url: endpoint,
      success: function (data) {
        if (data.success) {
          $('.form-upload-entity-id', context).val('deleted');
          $(statusDiv).html('File deleted successfully!');
          $('.form-delete-button', context).hide();
        }
        else {
          /* Allow to try again */
          $('button', context).removeAttr('disabled');

          if (data.error) {
            $(statusDiv).html('<span class="error">Operation failed! Reason: ' + data.error + '</span>');
          }
          else {
            $(statusDiv).html('<span class="error">Operation failed!</span>');
          }
        }
      },
      error: function() {
        $(statusDiv).html('<span class="error">Operation error. Please try again later.</span>');
      },
    });
  }
})(jQuery);
