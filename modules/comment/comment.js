Ophal.extend('comment', function ($) {

var renderHandlers = {};

renderHandlers.onload = function() {
  var entity = Ophal.settings.entity.current;
  var core = Ophal.settings.core;

  /* Fetch current content comments */
  $.ajax({
    type: 'GET',
    url: core.base.route + 'comment/fetch/' + entity.id,
    contentType: 'application/json; charset=utf-8',
    processData: false,
    success: function (data) {
      if (data.success) {
        var count = 0;
        var wrapper =
          $('<div class="comments-wrapper"><span class="no-comments">' +
          Ophal.t('There are no comments.') + '</span></div>')
        ;
        for (k in data.list) {
          if (count == 0) {
            $('.no-comments', wrapper).remove();
          }
          $(wrapper).prepend(data.list[k].rendered);
          count++;
        }
        $('#content').append(wrapper);
        Ophal.scroll_down();
        $(document).trigger('ophal:comments:load', [$('.comments-wrapper'), data]);
      }
      else {
        Ophal.set_message('Comments not available.');
      }
    },
    error: function() {
      Ophal.set_message('Error loading comments.');
    },
  });
}

renderHandlers.onclick = function() {
  var wrapper = $('<a class="button" href="#comments-wrapper">'+ Ophal.t('Show comments') + '</a>');
  $('#content > div').append(wrapper);
  $('#content > div .button').click(function() {
    $(this).html(Ophal.t('Loading...'));
    $('#content > div').html('');
    renderHandlers.onload();
  });
}

$(document).ready(function() {
  var config = Ophal.settings.comment;

  /* Load comments if current page is an entity */
  if ('entity' in Ophal.settings) {
    renderHandlers[config.render_handler]();
  }

  $('.comment-form').submit(function() {
    var id = $(this).attr('entity:id');
    var entityId = $(this).attr('entity:entity_id');
    var parentId = $(this).attr('entity:parent_id');

    var endpoint = '/comment/save';
    if (id) {
      endpoint += '/' + id;
    }

    var entity = {
      type: 'comment',
      entity_id: entityId,
      parent_id: parentId,
      body: $('textarea', this).val(),
    }
    $(document).trigger('ophal:entity:save', {context: this, entity: entity});

    /* Submit data */
    $.ajax({
      type: 'POST',
      url: endpoint,
      contentType: 'application/json; charset=utf-8',
      data: JSON.stringify(entity),
      dataType: 'json',
      processData: false,
      success: function (data) {
        if (data.success) {
          window.location = data.return_path + '#comment-' + data.id;
        }
        else {
          $(this).removeAttr('disabled');
          if (data.error) {
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

    return false;
  });
  $('.comment-form textarea').keydown(function(event) {
    if (event.keyCode == 13) {
      $(this).attr('disabled', 'disabled');
      event.preventDefault();
      event.returnValue = false;
      $(this).closest("form").submit();
    }
  })
});

});
