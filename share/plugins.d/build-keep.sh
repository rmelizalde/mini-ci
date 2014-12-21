declare BUILD_KEEP

plugin_on_load_config_pre_build_keep() {
    BUILD_ARCHIVE_WORKSPACE="0"
}

plugin_on_tasks_finish_post_build_keep() {
    if [[ "$BUILD_KEEP" -gt 0 ]]; then
        while read num; do
            if [[ -d "$BUILDS_DIR/$num" ]]; then
                rm -r "$BUILDS_DIR/$num"
            fi
        done < <(seq 1 $(( $BUILD_NUMBER - $BUILD_KEEP)))
    fi
}
