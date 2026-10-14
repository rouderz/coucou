// Lumo runs without a console window: The character is the whole UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    coucou_lib::run()
}
