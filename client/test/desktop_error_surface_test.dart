// M13 (issue #143) — DesktopErrorSurface renders any of the twelve typed
// states through one shape ("what, why, what still works, what to do"),
// choosing its container from the state's treatment.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/domain/desktop_error_state.dart';
import 'package:plotlines_client/presentation/widgets/desktop_error_surface.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    DesktopErrorState state, {
    DesktopErrorContent? content,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: PlotTheme.light(),
        home: DesktopErrorSurface(
          state: state,
          content: content ??
              DesktopErrorContent(headline: 'Headline for ${state.name}', why: 'the stated cause'),
        ),
      ),
    );
  }

  testWidgets('a full-screen block state renders a Scaffold with headline and cause', (tester) async {
    await pump(tester, DesktopErrorState.sidecarWontStart,
        content: const DesktopErrorContent(
          headline: 'The routing engine won\'t start',
          why: 'it exited twice at launch',
        ));
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('The routing engine won\'t start'), findsOneWidget);
    expect(find.text('it exited twice at launch'), findsOneWidget);
  });

  testWidgets('a retryable state shows the retry; a non-retryable one does not', (tester) async {
    var retried = 0;
    await pump(tester, DesktopErrorState.sidecarWontStart,
        content: DesktopErrorContent(
          headline: 'won\'t start',
          why: 'because',
          onRetry: () => retried++,
        ));
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);

    // noRoutePossible is not retryable — a retry callback is ignored.
    await pump(tester, DesktopErrorState.noRoutePossible,
        content: DesktopErrorContent(headline: 'no route', why: 'bands conflict', onRetry: () {}));
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a blocking state hides "what still works"; a non-blocking one shows it', (tester) async {
    await pump(tester, DesktopErrorState.sidecarStarting,
        content: const DesktopErrorContent(
          headline: 'starting',
          why: 'usually eight seconds',
          whatStillWorks: ['Reading this trip works'],
        ));
    expect(find.text('Reading this trip works'), findsNothing);

    await pump(tester, DesktopErrorState.sidecarDiedMidSession,
        content: const DesktopErrorContent(
          headline: 'engine stopped',
          why: 'it exited again',
          whatStillWorks: ['Reading and editing this trip works'],
        ));
    expect(find.text('Reading and editing this trip works'), findsOneWidget);
  });

  testWidgets('the banner state renders inline (no Scaffold) so the app stays beneath it',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PlotTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              const DesktopErrorSurface(
                state: DesktopErrorState.sidecarDiedMidSession,
                content: DesktopErrorContent(headline: 'engine down', why: 'died twice'),
              ),
              const Expanded(child: Text('the trip, still on screen')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('engine down'), findsOneWidget);
    expect(find.text('the trip, still on screen'), findsOneWidget);
  });

  testWidgets('an inline-card state renders a PlotCard', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PlotTheme.light(),
        home: Scaffold(
          body: DesktopErrorSurface(
            state: DesktopErrorState.layerExtractionFailed,
            content: const DesktopErrorContent(
              headline: 'Layer extraction failed',
              why: 'the historic layer timed out',
              whatStillWorks: ['The other four layers are live'],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(PlotCard), findsOneWidget);
    expect(find.text('The other four layers are live'), findsOneWidget);
  });

  testWidgets('an inline-notice state renders the cause quietly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PlotTheme.light(),
        home: Scaffold(
          body: DesktopErrorSurface(
            state: DesktopErrorState.elevationVoidOrMissingTile,
            content: const DesktopErrorContent(
              headline: 'Elevation void',
              why: 'two tiles have no data; those points read as zero',
            ),
          ),
        ),
      ),
    );
    expect(find.text('two tiles have no data; those points read as zero'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget); // the test's own, not the surface's
  });

  testWidgets('the "elsewhere" state renders nothing on this surface', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PlotTheme.light(),
        home: Scaffold(
          body: DesktopErrorSurface(
            state: DesktopErrorState.noClustersFoundInBbox,
            content: const DesktopErrorContent(headline: 'no clusters', why: 'analysis found nothing'),
          ),
        ),
      ),
    );
    expect(find.text('no clusters'), findsNothing);
    expect(find.text('analysis found nothing'), findsNothing);
  });

  testWidgets('showAsDialog puts export-failed in a modal with a retry over the unchanged trip',
      (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: PlotTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => PlotButton(
              label: 'go',
              onPressed: () => DesktopErrorSurface.showAsDialog(
                context,
                content: DesktopErrorContent(
                  headline: 'Export didn\'t finish',
                  why: 'the folder is read-only',
                  whatStillWorks: ['Your trip is unchanged and still open'],
                  onRetry: () => retried++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('the folder is read-only'), findsOneWidget);
    expect(find.text('Your trip is unchanged and still open'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retried, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('extra actions render after the retry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PlotTheme.light(),
        home: Scaffold(
          body: DesktopErrorSurface(
            state: DesktopErrorState.noDataForArea,
            content: DesktopErrorContent(
              headline: 'No routable data',
              why: 'the extract came back empty',
              actions: [PlotButton(label: 'Choose area', onPressed: () {})],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Choose area'), findsOneWidget);
  });
}
