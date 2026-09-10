import SwiftUI

/// Full "What's trending" list reached via Import's "See all" link —
/// infinite-scrolling, paginated through `TrendingBooksViewModel`. Shares
/// that same view-model instance with the home screen's preview row, so
/// this continues paginating from wherever the row left off rather than
/// starting over from page 1.
struct AllTrendingBooksView: View {
    @ObservedObject var viewModel: TrendingBooksViewModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(viewModel.books) { book in
                    TrendingBookCard(book: book, coverSize: 160)
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded(currentItem: book) }
                        }
                }
            }
            .padding()

            if viewModel.isLoadingMore {
                ProgressView()
                    .padding(.bottom, 24)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("What's trending")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    NavigationStack {
        AllTrendingBooksView(viewModel: TrendingBooksViewModel())
    }
}
