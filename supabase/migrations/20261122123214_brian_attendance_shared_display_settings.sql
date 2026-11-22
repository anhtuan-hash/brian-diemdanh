ALTER TABLE public.bes_attendance_global_settings
  ADD COLUMN display_wallpaper_opacity smallint NOT NULL DEFAULT 15
    CONSTRAINT attendance_display_wallpaper_opacity_range CHECK (display_wallpaper_opacity BETWEEN 0 AND 40),
  ADD COLUMN display_clear_surfaces boolean NOT NULL DEFAULT true;
