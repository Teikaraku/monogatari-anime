import 'package:kazumi/modules/comments/comment_item.dart';

class EpisodeCommentResponse {
  List<EpisodeCommentItem> commentList;

  EpisodeCommentResponse({
    required this.commentList,
  });

  factory EpisodeCommentResponse.fromJson(List<dynamic> json) {
    List<EpisodeCommentItem>? resCommentList =
        (json as List?)?.map((i) => EpisodeCommentItem.fromJson(i)).toList();
    return EpisodeCommentResponse(
      commentList: resCommentList ?? <EpisodeCommentItem>[],
    );
  }

  factory EpisodeCommentResponse.fromTemplate() {
    return EpisodeCommentResponse(
      commentList: [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'list': commentList,
    };
  }
}
